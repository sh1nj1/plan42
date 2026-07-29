module CollavreGithub
  class WebhooksController < ActionController::API
    def create
      event = github_event_header
      if event.blank?
        Rails.logger.warn("GitHub event header missing; rejecting request")
        return head :bad_request
      end

      raw_body = request.raw_post.presence || request.body.read
      payload = parse_payload(raw_body)
      @repository_link = find_repository_link(payload)
      unless valid_signature?(raw_body)
        # A rejected delivery is otherwise visible ONLY as a red row in
        # GitHub's hook UI. On this side it leaves no trace at all: the
        # deliveries ledger is written below, after verification. Everyone
        # watching the topic just sees silence where PR comments should be.
        #
        # Announced ONLY when no secret could be resolved — i.e. the delivery
        # named a repository this app cannot identify. That is the failure that
        # is worth a human's attention (a rename, or a link that was never
        # provisioned) and it is the one that stays broken until someone acts.
        #
        # A signature MISMATCH is deliberately silent. There the repository was
        # identified and a secret was found; the request simply did not sign
        # with it, which is what an attacker probing the endpoint looks like.
        # Announcing that would hand any unauthenticated caller who can guess a
        # monitored repository's name a way to post into that topic on demand.
        announce_webhook_auth_failure(payload) if webhook_secret.blank?
        return head :unauthorized
      end

      # Idempotency claim. Deliberately AFTER signature verification: the claim
      # writes a row keyed by an attacker-supplied header, so an unauthenticated
      # caller must not be able to pre-claim a GUID and have GitHub's real
      # delivery dropped as a duplicate.
      #
      # `head :ok` on a lost claim (not an error status). An error status would
      # mark a delivery failed that was in fact handled, and a failed delivery
      # is the one thing an operator is asked to act on.
      #
      # Worth stating plainly, because several decisions below turn on it:
      # GitHub NEVER redelivers automatically. A 4xx, a 5xx or a timeout is
      # simply recorded as failed. Recovery is a human pressing Redeliver or a
      # scheduled script walking the deliveries API, and only inside GitHub's
      # 3-day window. So an error status here buys no automatic retry — it only
      # spends the one signal that recovery depends on.
      # The token, not the GUID, is this run's proof of ownership. Ownership can
      # be taken away mid-run (see WebhookDelivery::STALE_CLAIM_AFTER), so both
      # the release below and the mark_processed! at the end are scoped to it.
      #
      # The claim is lost in two states that this request cannot tell apart at
      # the moment it answers: the owner has finished, or the owner is still
      # running and may yet fail. Both answer 200, i.e. this branch ASSUMES the
      # owner succeeds. That assumption is deliberate, and it is safe because it
      # does not consume the owner's own recovery: a failing owner answers 5xx
      # on ITS delivery, and each hook (and each Redeliver press) is a separate
      # delivery with a separate response. So a lost claim never reduces
      # recoverability below that of any other failed delivery.
      #
      # Answering a retryable status here instead would be strictly worse. Two
      # hooks are fanned out in parallel and a delivery takes well under a
      # second, so the loser overlaps the owner on essentially every event: one
      # hook would show a permanent stream of failed deliveries for events that
      # were handled correctly — destroying the very signal (a red delivery
      # means look at me) that the release-and-redeliver recovery depends on.
      # Waiting for processed_at fares no better: it holds the connection open
      # against GitHub's ~10s delivery timeout while a different request works,
      # and cannot separate a slow owner from a dead one — only
      # STALE_CLAIM_AFTER does that, and it is far longer than the timeout.
      #
      # What the assumption does cost is diagnosability, so the two states are
      # distinguished in the log: a Redeliver pressed while the owner is still
      # running is answered 200 and, if that owner then fails, the event is left
      # for the owner's 5xx to recover. Only the log says which of the two
      # happened.
      claim_token = CollavreGithub::WebhookDelivery.claim(delivery_guid, event: event)
      unless claim_token
        # Block form: `claim_state_for_log` costs a query, and this branch is
        # taken on nearly every event once a repository carries two hooks, so it
        # must not run when info logging is off.
        Rails.logger.info do
          "[CollavreGithub] duplicate delivery #{delivery_guid} (#{event}); skipping " \
            "(#{claim_state_for_log})"
        end
        return head :ok
      end

      begin
        process_delivery(event, payload)
      rescue => e
        # The claim must not outlive a failed run. This request answers 5xx,
        # and any redelivery that follows — always operator- or script-driven,
        # never automatic — carries the SAME GUID. With the row still in
        # place that redelivery would take the duplicate branch above, answer
        # 200 and drop the event permanently, which is strictly worse than the
        # duplicate this ledger exists to prevent.
        #
        # Processing is therefore at-least-once: a run that fails halfway can
        # repeat the side effects it already performed. Wrapping the whole
        # delivery in one transaction would make it exactly-once but would
        # break `dispatch_to_channels`, which isolates a broken channel with a
        # rescue — under Postgres a rescued statement error leaves the
        # enclosing transaction aborted, so every sibling channel would fail
        # too. Repeating a comment beats losing the event and taking every
        # other channel down with it.
        Rails.logger.error(
          "[CollavreGithub] delivery #{delivery_guid} (#{event}) failed, releasing claim: #{e.class}: #{e.message}"
        )
        CollavreGithub::WebhookDelivery.release(delivery_guid, claim_token)
        raise
      end

      complete_delivery(event, claim_token)
      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    # Why the claim was lost, for the log line only — never for the response,
    # which is 200 in every case. Read separately from `claim` because the
    # answer is advisory: the owner can finish between the failed claim and
    # this read, and a state that is already stale is still the closest thing
    # to an answer available to a request that owns nothing.
    #
    # `released` is the state worth grepping for. It means the owner failed and
    # dropped the claim, so this delivery was dismissed with nobody left
    # holding the event — recovery rests entirely on the owner's own 5xx.
    def claim_state_for_log
      delivery = CollavreGithub::WebhookDelivery.find_by(delivery_guid: delivery_guid)
      return "released by a failed owner" if delivery.nil?

      delivery.processed_at ? "already processed" : "owner still in flight"
    end

    # Bounded because the ledger write is a single UPDATE on a row this run
    # already owns: it either goes through on a retry or the database is gone,
    # and spinning would only hold the request open while GitHub times out.
    MARK_PROCESSED_ATTEMPTS = 3

    # Stamping the ledger is part of completing the delivery, not an epilogue
    # to it. Left outside the failure handling, a transient database error here
    # stranded the claim unprocessed *after* every side effect had already run,
    # and a redelivery arriving past STALE_CLAIM_AFTER took the row over and
    # repeated all of them.
    #
    # A failure that outlives the retries does NOT release the claim, which is
    # where this parts from the rescue around `process_delivery`. There the
    # event was never handled, so freeing the GUID is what saves it. Here the
    # event *was* handled: releasing would hand the next redelivery a clean
    # slate and guarantee the repeat this is meant to avoid, while keeping the
    # claim leaves a redelivery inside the stale window correctly dismissed.
    #
    # For the same reason the request still answers 200. Processing succeeded —
    # only our bookkeeping did not — and a 5xx here would invite the very
    # redelivery whose side effects we cannot afford to run twice.
    def complete_delivery(event, claim_token)
      attempts = 0
      begin
        attempts += 1
        CollavreGithub::WebhookDelivery.mark_processed!(delivery_guid, claim_token)
      rescue => e
        retry if attempts < MARK_PROCESSED_ATTEMPTS

        Rails.logger.error(
          "[CollavreGithub] delivery #{delivery_guid} (#{event}) was processed but could not be " \
          "marked processed after #{attempts} attempts; claim kept to keep a redelivery inside " \
          "#{CollavreGithub::WebhookDelivery::STALE_CLAIM_AFTER.inspect} deduplicated: #{e.class}: #{e.message}"
        )
      end
    end

    def process_delivery(event, payload)
      payload = payload.presence || {}

      # Rename first, and terminally: the whole point is to repair the routing
      # keys before anything downstream reads them. The other `repository`
      # actions (archived, publicized, transferred, ...) are deliberately
      # dropped rather than formatted into the creative feed — subscribing to
      # this event is a routing-maintenance concern, not a feed feature.
      if event == "repository"
        handle_repository_renamed(payload) if payload["action"] == "renamed"
        return
      end

      repair_repository_identity_from_verified_hook(payload)

      # A delivery that verified is proof this payload really describes a
      # repository we are linked to, so it is the only safe place to learn the
      # id. Doing it at lookup time instead would let an unauthenticated caller
      # repoint a link's routing key at a repository they control.
      backfill_repository_ids(payload)
      clear_auth_failure_notices(payload)

      # Process all links for this repo (same repo can be linked to multiple creatives)
      all_links = all_repository_links_for(payload)
      all_links.each do |link|
        create_system_comment_for(link, event, payload) if link.creative && !channel_only_event?(event)
        trigger_markdown_sync_for(link, event, payload) if link.markdown_sync_enabled?
      end

      maybe_auto_attach_channel(event, payload)
      dispatch_to_channels(event, payload)
    end

    # `WebhookProvisioner` auto-subscribes every repo webhook to the events
    # GithubPrChannel needs (`issue_comment`, `pull_request_review`,
    # `pull_request_review_comment`). Those events must only reach attached
    # PR channels — letting them through the creative feed would spam every
    # linked creative with system comments from issues/PRs that nobody asked
    # to monitor. `push` and `pull_request` continue to flow into the feed.
    def channel_only_event?(event)
      CollavreGithub::WebhookProvisioner::CHANNEL_EVENTS.include?(event)
    end

    def maybe_auto_attach_channel(event, payload)
      return unless event == "pull_request" && %w[opened reopened].include?(payload["action"])
      # GitHub repo identifiers are case-insensitive; normalize so stored
      # channels (also lowercased) match incoming dispatch payloads regardless
      # of how the repo casing arrives from clients.
      repo = payload.dig("repository", "full_name")&.downcase
      pr_number = payload.dig("pull_request", "number")
      return unless repo && pr_number

      # `reopened` must resurrect ANY existing channel for this (repo, pr) — not
      # just channels whose PR body still contains a topic link. Manually attached
      # channels (via `pr_monitor`) and PRs whose body link was later removed both
      # have a valid channel but no link; without this branch, the body-link path
      # below would short-circuit and dispatch_to_channels (.active scope) would
      # skip the dismissed/detached row, leaving the chip hidden and the PR
      # unmonitored for the rest of its reopened life.
      reactivate_existing_channels_on_reopen(repo, pr_number, payload) if payload["action"] == "reopened"

      # Body-link path: only used to CREATE a new channel. Existing-channel paths
      # are intentionally handled above (reopened) or as a strict no-op (opened
      # redelivery — must not undo a user's X dismissal).
      body = payload.dig("pull_request", "body")
      topic_id = CollavreGithub::PrTopicLinkParser.call(body)
      return unless topic_id

      topic = Collavre::Topic.find_by(id: topic_id)
      return unless topic

      # Security: the PR description is attacker-controlled. Anyone able to open
      # a PR on this repo could otherwise drop a link to an unrelated tenant's
      # topic and have subsequent PR comments injected there. Only auto-attach
      # when the topic's creative — or any of its ancestors — is linked to this
      # repo (RepositoryLink applies to the whole subtree).
      linked_creative_ids = all_repository_links_for(payload).map(&:creative_id)
      creative = topic.creative
      return unless creative
      candidate_ids = [ creative.id ] + creative.ancestors.pluck(:id)
      return if (linked_creative_ids & candidate_ids).empty?

      existing = GithubPrChannel.where(topic_id: topic.id).find do |c|
        c.repo_full_name.to_s.downcase == repo && c.pr_number == pr_number
      end
      # Existing channel: strict no-op. `reopened` was already handled by the
      # repo+pr scan above; `opened` redelivery must leave dismissed_at intact.
      return existing if existing

      GithubPrChannel.create!(
        topic_id: topic.id,
        config: { "repo_full_name" => repo, "pr_number" => pr_number, "pr_state" => "open" }
      )
    rescue ActiveRecord::RecordNotUnique
      # concurrent webhook safe
    rescue => e
      Rails.logger.error("[CollavreGithub] auto-attach failed: #{e.class}: #{e.message}")
    end

    # Resurrect every existing channel for (repo, pr_number) on `pull_request.
    # reopened`, regardless of whether the PR description currently contains a
    # topic link. Mirrors dispatch's scope re-validation so a channel whose
    # creative is no longer linked to this repo is NOT resurrected.
    def reactivate_existing_channels_on_reopen(repo, pr_number, payload)
      linked_creative_ids = all_repository_links_for(payload).map(&:creative_id)
      return if linked_creative_ids.empty?

      GithubPrChannel.find_each do |channel|
        next unless channel.repo_full_name.to_s.downcase == repo && channel.pr_number == pr_number
        next unless channel_in_repo_scope?(channel, linked_creative_ids)

        begin
          # Row-level lock + re-read guards against duplicate reopened announcements
          # when two `pull_request.reopened` deliveries for the same dismissed/
          # detached channel arrive concurrently (GitHub retries on 5xx, or
          # duplicate fan-out). Without it, both requests can read was_inactive=true
          # before either clears dismissed_at, then both inject the reopened
          # message. Mirrors the close-path with_lock in dispatch_to_channels.
          channel.with_lock do
            was_inactive = !channel.active? || !channel.dismissed_at.nil?
            if was_inactive || channel.pr_state != "open"
              channel.state = :active unless channel.active?
              channel.dismissed_at = nil unless channel.dismissed_at.nil?
              channel.pr_state = "open" if channel.pr_state != "open"
              channel.save!
            end
            # When the chip silently reappears after dismiss/detach, inject a
            # one-line announcement so the user can trace the lifecycle —
            # mirrors the attach announcement on first create.
            if was_inactive
              begin
                channel.inject_into_topic!(channel.reopened_message)
              rescue => e
                Rails.logger.error("[CollavreGithub] reopened announce failed: #{e.class}: #{e.message}")
              end
            end
          end
        rescue => e
          # Per-channel isolation: one bad row must not block sibling channels.
          Rails.logger.error(
            "[CollavreGithub] reopen reactivate failed for channel #{channel.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end

    def dispatch_to_channels(event, payload)
      repo = payload.dig("repository", "full_name")&.downcase
      pr_number = extract_pr_number(event, payload)
      return if repo.blank? || pr_number.nil?

      # Re-resolve which creatives are linked to this repo on every dispatch.
      # The auto-attach guard validated the link at creation time, but a
      # RepositoryLink can be removed or a topic can be moved to a different
      # creative subtree after attachment. Without re-validating here, an
      # orphaned channel would keep receiving cross-tenant PR events.
      linked_creative_ids = all_repository_links_for(payload).map(&:creative_id)

      # Ruby-level filter for DB portability (SQLite dev/test, Postgres prod).
      # Future optimization: switch to a jsonb-portable query once an established
      # pattern exists in this codebase. Compare repo names case-insensitively
      # so legacy mixed-case rows continue to match the canonical lowercase
      # payload value.
      GithubPrChannel.active.find_each do |channel|
        next unless channel.repo_full_name.to_s.downcase == repo && channel.pr_number == pr_number
        next unless channel_in_repo_scope?(channel, linked_creative_ids)

        begin
          # Row-level lock + re-check guards against duplicate dispatch when the
          # same webhook is redelivered (GitHub retries on 5xx) or two webhooks
          # arrive concurrently. Without it, both processes read state=active
          # and each inject the closing comment. The query-level .active scope
          # alone does not race-protect the inject+detach window.
          channel.with_lock do
            next unless channel.active?

            injected = channel.handle(event: event, payload: payload)
            next if injected.nil?

            channel.inject_into_topic!(injected)
            # Detach AFTER injecting the closing message so the chip remains
            # visible (now with merged/closed badge) until dismissed by the user.
            channel.detach! if event == "pull_request" && payload["action"] == "closed"
          end
        rescue => e
          # Isolate per-channel failures so one broken channel does not block
          # sibling channels monitoring the same PR.
          Rails.logger.error(
            "[CollavreGithub] channel #{channel.id} dispatch failed: #{e.class}: #{e.message}"
          )
        end
      end
    end

    # A channel is in-scope iff its topic's creative — or any ancestor — is
    # still listed in a RepositoryLink for the webhook's repo. Mirrors the
    # auto-attach guard so removing a link severs the dispatch, not just the
    # ability to create new monitors.
    def channel_in_repo_scope?(channel, linked_creative_ids)
      return false if linked_creative_ids.empty?

      creative = channel.topic&.creative
      return false unless creative

      candidate_ids = [ creative.id ] + creative.ancestors.pluck(:id)
      (linked_creative_ids & candidate_ids).any?
    end

    def extract_pr_number(event, payload)
      case event
      when "issue_comment"
        n = payload.dig("issue", "number")
        n if payload.dig("issue", "pull_request")
      when "pull_request_review_comment", "pull_request_review", "pull_request"
        payload.dig("pull_request", "number")
      end
    end

    def create_system_comment_for(link, event, payload)
      creative = link.creative&.effective_origin
      return unless creative

      content = format_github_event(event, payload)

      creative.comments.create!(
        user: nil,
        content: content,
        private: false
      )
    end

    def format_github_event(event, payload)
      case event
      when "pull_request"
        format_pull_request(payload)
      when "push"
        format_push(payload)
      when "issues"
        format_issue(payload)
      when "issue_comment"
        format_issue_comment(payload)
      else
        format_generic_event(event, payload)
      end
    end

    def format_pull_request(payload)
      pr = payload["pull_request"] || {}
      action = payload["action"]
      number = pr["number"]
      title = pr["title"]
      url = pr["html_url"]
      user = pr.dig("user", "login")
      merged = pr["merged"]
      repo = payload.dig("repository", "full_name")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('pull_request.title', action: action_label(action, merged))}"
      lines << ""
      lines << "**#{t.call('pull_request.repository')}:** #{repo}"
      lines << "**#{t.call('pull_request.pr')}:** [##{number} #{title}](#{url})"
      lines << "**#{t.call('pull_request.author')}:** #{user}"
      lines << "**#{t.call('pull_request.action')}:** #{action}#{merged ? " #{t.call('pull_request.merged')}" : ''}"

      if pr["body"].present?
        lines << ""
        lines << "**#{t.call('pull_request.description')}:**"
        lines << pr["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_push(payload)
      repo = payload.dig("repository", "full_name")
      ref = payload["ref"]
      branch = ref&.sub("refs/heads/", "")
      pusher = payload.dig("pusher", "name")
      commits = payload["commits"] || []
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('push.title', branch: branch)}"
      lines << ""
      lines << "**#{t.call('push.repository')}:** #{repo}"
      lines << "**#{t.call('push.branch')}:** #{branch}"
      lines << "**#{t.call('push.pusher')}:** #{pusher}"
      lines << "**#{t.call('push.commits')}:** #{commits.size}"

      if commits.any?
        lines << ""
        lines << "**#{t.call('push.recent_commits')}:**"
        commits.first(5).each do |commit|
          message = commit["message"].to_s.lines.first&.strip || t.call("push.no_message")
          sha = commit["id"].to_s[0, 7]
          lines << "- `#{sha}` #{message.truncate(80)}"
        end
        lines << "- #{t.call('push.more')}" if commits.size > 5
      end

      lines.join("\n")
    end

    def format_issue(payload)
      issue = payload["issue"] || {}
      action = payload["action"]
      number = issue["number"]
      title = issue["title"]
      url = issue["html_url"]
      user = issue.dig("user", "login")
      repo = payload.dig("repository", "full_name")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('issue.title', action: action)}"
      lines << ""
      lines << "**#{t.call('issue.repository')}:** #{repo}"
      lines << "**#{t.call('issue.issue')}:** [##{number} #{title}](#{url})"
      lines << "**#{t.call('issue.author')}:** #{user}"
      lines << "**#{t.call('issue.action')}:** #{action}"

      if action == "opened" && issue["body"].present?
        lines << ""
        lines << "**#{t.call('issue.description')}:**"
        lines << issue["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_issue_comment(payload)
      issue = payload["issue"] || {}
      comment = payload["comment"] || {}
      action = payload["action"]
      number = issue["number"]
      title = issue["title"]
      url = comment["html_url"]
      user = comment.dig("user", "login")
      repo = payload.dig("repository", "full_name")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('issue_comment.title', action: action, number: number)}"
      lines << ""
      lines << "**#{t.call('issue_comment.repository')}:** #{repo}"
      lines << "**#{t.call('issue_comment.issue')}:** ##{number} #{title}"
      lines << "**#{t.call('issue_comment.comment_by')}:** #{user}"
      lines << "**#{t.call('issue_comment.link')}:** [#{t.call('issue_comment.view_comment')}](#{url})"

      if comment["body"].present?
        lines << ""
        lines << "**#{t.call('issue_comment.comment')}:**"
        lines << comment["body"].to_s.truncate(500)
      end

      lines.join("\n")
    end

    def format_generic_event(event, payload)
      repo = payload.dig("repository", "full_name")
      action = payload["action"]
      sender = payload.dig("sender", "login")
      t = method(:t_webhook)

      lines = []
      lines << "### #{t.call('generic.title', event: event.titleize)}"
      lines << ""
      lines << "**#{t.call('generic.repository')}:** #{repo}"
      lines << "**#{t.call('generic.action')}:** #{action}" if action
      lines << "**#{t.call('generic.sender')}:** #{sender}" if sender

      lines.join("\n")
    end

    def action_label(action, merged)
      t = method(:t_webhook)
      case action
      when "opened"
        t.call("actions.opened")
      when "closed"
        merged ? t.call("actions.merged") : t.call("actions.closed")
      when "reopened"
        t.call("actions.reopened")
      when "synchronize"
        t.call("actions.updated")
      when "ready_for_review"
        t.call("actions.ready_for_review")
      else
        action&.titleize || t.call("actions.event")
      end
    end

    def t_webhook(key, **options)
      I18n.t("collavre_github.webhooks.#{key}", **options)
    end

    def trigger_markdown_sync_for(link, event, payload)
      return unless event == "push"

      CollavreGithub::MarkdownSyncJob.perform_later(
        link.id,
        payload.as_json
      )
    end

    # [github_repository_id, lowercased_full_name] from a payload that may use
    # either string or symbol keys depending on how it was parsed.
    def repository_identity(payload)
      repo = payload&.dig("repository") || payload&.dig(:repository)
      return [ nil, nil ] if repo.blank?

      [
        repo["id"] || repo[:id],
        (repo["full_name"] || repo[:full_name]).to_s.downcase.presence
      ]
    end

    def links_for(payload)
      id, full_name = repository_identity(payload)
      CollavreGithub::RepositoryLink.for_repository(id: id, full_name: full_name)
    end

    def all_repository_links_for(payload)
      id, full_name = repository_identity(payload)
      return [ @repository_link ].compact if id.blank? && full_name.blank?

      links = links_for(payload).to_a
      return links if id.blank?

      # ID-backed rows are authoritative. A NULL-id name match is only a
      # sibling of the authenticated repository when it carries the same HMAC
      # secret; otherwise the name may be stale and reused by another repo.
      links.select do |link|
        link.repository_id.present? || secrets_match?(link.webhook_secret, webhook_secret)
      end
    end

    def find_repository_link(payload)
      if payload.blank?
        Rails.logger.warn("[GitHub Webhook] Payload is blank")
        return
      end

      id, full_name = repository_identity(payload)
      if id.blank? && full_name.blank?
        Rails.logger.warn("[GitHub Webhook] Repository identity missing in payload")
        return
      end

      candidates = links_for(payload)
      # A NULL-id name match is only a legacy candidate. Prefer the stable ID
      # row for signature lookup so a stale same-name row with another secret
      # cannot make a legitimate delivery fail depending on database order.
      authoritative = candidates.where(repository_id: id).first
      return authoritative if authoritative

      hook_link = repository_link_for_hook_id(id)
      if hook_link
        @repository_link_from_hook_id = true
        return hook_link
      end

      candidates.first
    end

    # GitHub includes the stable hook registration id on every delivery. It is
    # safe to use as a secret-selection fallback because no state changes until
    # the request passes HMAC verification. This recovers the exact missed-
    # rename case: both the link and channel still carry the old repository
    # name, while the payload carries only the new one.
    def repository_link_for_hook_id(repository_id)
      raw_hook_id = request.headers["X-GitHub-Hook-ID"].to_s
      hook_id = Integer(raw_hook_id, 10, exception: false)
      return unless hook_id&.between?(1, (2**63) - 1)

      candidates = CollavreGithub::RepositoryLink.where(webhook_hook_id: hook_id)
      if repository_id.present?
        candidates = candidates.where(repository_id: [ nil, repository_id ])
        candidates.where(repository_id: repository_id).first || candidates.first
      else
        candidates.first
      end
    end

    # Once a hook-id fallback has passed HMAC verification, the delivery proves
    # both the stable repository id and its current canonical name. Repair the
    # link and its in-scope channels before ordinary fan-out resolves them.
    def repair_repository_identity_from_verified_hook(payload)
      return unless @repository_link_from_hook_id

      id, full_name = repository_identity(payload)
      return if id.blank? || full_name.blank?

      synchronized = CollavreGithub::RepositoryIdentitySynchronizer.call(
        anchor: @repository_link,
        repository_id: id,
        full_name: full_name,
        trusted_hook_id: request.headers["X-GitHub-Hook-ID"],
        trusted_secret: webhook_secret
      )
      @repository_link = synchronized.find do |link|
        link.creative_id == @repository_link.creative_id
      end || @repository_link
    end

    # Stamp the stable id onto links that predate id-based routing. Scoped to
    # links this repository actually resolved to, carrying the same secret that
    # authenticated this delivery, and only ever fills a NULL. Name matching
    # alone is not proof of identity: a stale NULL-id link may carry a name that
    # GitHub has since assigned to another repository.
    def backfill_repository_ids(payload)
      id, _full_name = repository_identity(payload)
      return if id.blank?

      links_for(payload).each do |link|
        next if link.repository_id.present?
        next unless secrets_match?(link.webhook_secret, webhook_secret)

        link.update_column(:repository_id, id)
      end
    end

    # GitHub sends `repository.renamed` with the NEW `full_name` and only the
    # short name of the old one, so the previous full name has to be rebuilt
    # from the owner login. The id is matched too, and matters more: it is what
    # lets a link that was already backfilled be found even when its stored
    # name matches nothing in the payload.
    #
    # Note the ordering dependency this creates. A link whose `repository_id`
    # is still NULL when its repository is renamed cannot be repaired by this
    # handler — the delivery carrying the rename is itself rejected 401,
    # because the secret is looked up by the same keys. Backfill is what makes
    # this handler reachable; `announce_webhook_auth_failure` is what covers
    # the links that never got one.
    def handle_repository_renamed(payload)
      repo = payload["repository"] || {}
      new_full_name = (repo["full_name"] || repo[:full_name]).to_s
      return if new_full_name.blank?

      repo_id = repo["id"] || repo[:id]
      owner = repo.dig("owner", "login")
      from = payload.dig("changes", "repository", "name", "from")
      old_full_name = ("#{owner}/#{from}" if owner.present? && from.present?)

      # An authenticated rename must never mutate every row carrying the old
      # name. GitHub allows that name to be reused by another repository after
      # the rename, and a delayed/redelivered event would otherwise capture the
      # new repository's links and channels too.
      #
      # ID-backed rows are authoritative. The legacy fallback is restricted to
      # unbackfilled rows carrying the SAME secret that authenticated this
      # delivery; this preserves fan-out for a half-backfilled repository
      # without trusting the now-reusable name by itself.
      links = repo_id.present? ? CollavreGithub::RepositoryLink.where(repository_id: repo_id).to_a : []
      if old_full_name.present? && webhook_secret.present?
        legacy = CollavreGithub::RepositoryLink
          .where(repository_id: nil)
          .where("LOWER(repository_full_name) = ?", old_full_name.downcase)
          .select { |link| secrets_match?(link.webhook_secret, webhook_secret) }
        links.concat(legacy)
      end
      links.uniq!(&:id)

      renamed_creative_ids = []
      links.each do |link|
        if link.repository_full_name == new_full_name && link.repository_id.to_s == repo_id.to_s
          renamed_creative_ids << link.creative_id
          next
        end

        begin
          link.update_columns(repository_full_name: new_full_name, repository_id: repo_id)
          renamed_creative_ids << link.creative_id
        rescue ActiveRecord::RecordNotUnique
          # The creative is already linked to the repository under its new
          # name. Only treat that row as the same repository when its stable id
          # agrees; otherwise leave both it and the creative's channels alone.
          survivor = CollavreGithub::RepositoryLink
            .where(creative_id: link.creative_id)
            .where("LOWER(repository_full_name) = ?", new_full_name.downcase)
            .first
          if survivor&.repository_id.to_s == repo_id.to_s
            merge_repository_links!(obsolete: link, survivor: survivor)
            renamed_creative_ids << link.creative_id
          else
            Rails.logger.warn(
              "[CollavreGithub] rename collision for link #{link.id}: #{new_full_name} in " \
              "creative #{link.creative_id} belongs to repository #{survivor&.repository_id.inspect}"
            )
          end
        end
      end

      rename_channels(old_full_name, new_full_name, renamed_creative_ids) if old_full_name
      Rails.logger.info("[CollavreGithub] repository renamed #{old_full_name.inspect} -> #{new_full_name}")
    end

    # A delayed rename can meet a link that was already created under the new
    # name in the same creative. Leaving both rows behind would make every
    # subsequent ID lookup process that creative twice. Keep the new-name row,
    # align it with the secret that authenticated the delivery, preserve the
    # obsolete row's sync/registration state where the survivor has none, and
    # remove the duplicate.
    def merge_repository_links!(obsolete:, survivor:)
      survivor.update!(
        webhook_secret: webhook_secret,
        webhook_hook_id: survivor.webhook_hook_id || obsolete.webhook_hook_id,
        markdown_sync_enabled: survivor.markdown_sync_enabled? || obsolete.markdown_sync_enabled?,
        markdown_root_creative_id: survivor.markdown_root_creative_id || obsolete.markdown_root_creative_id,
        sync_branch: survivor.sync_branch.presence || obsolete.sync_branch,
        last_synced_at: [ survivor.last_synced_at, obsolete.last_synced_at ].compact.max
      )
      obsolete.destroy!
    end

    # Channels carry their own copy of the repo name (dispatch matches on it),
    # so renaming the links alone would leave every attached PR chip orphaned.
    def rename_channels(old_full_name, new_full_name, renamed_creative_ids)
      old = old_full_name.downcase
      GithubPrChannel.find_each do |channel|
        next unless channel.repo_full_name.to_s.downcase == old
        next unless channel_in_repo_scope?(channel, renamed_creative_ids)

        begin
          channel.update!(config: channel.config.merge("repo_full_name" => new_full_name))
        rescue => e
          Rails.logger.error(
            "[CollavreGithub] rename failed for channel #{channel.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end

    def secrets_match?(left, right)
      left = left.to_s
      right = right.to_s
      return false if left.bytesize != right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    # How long a channel stays quiet after announcing a rejected delivery.
    # GitHub retries nothing, but a busy repository produces a steady stream of
    # events and every one of them fails the same way — without this the topic
    # would fill with identical warnings.
    AUTH_FAILURE_NOTICE_INTERVAL = 1.hour

    # Global guard on the channel query below. This path is reachable by
    # unauthenticated callers, so the payload's repository name must not be part
    # of the throttle key: otherwise a caller can cycle arbitrary names to force
    # one query and one cache entry per request. A short global interval bounds
    # the work while still letting independently broken repositories announce
    # promptly. `unless_exist` makes concurrent claims atomic on cache stores
    # that support it; NullStore fails open and preserves the warning.
    AUTH_FAILURE_SCAN_INTERVAL = 1.minute
    AUTH_FAILURE_SCAN_CACHE_KEY = "collavre_github:auth_failure_scan".freeze

    # Announce a rejected delivery in every topic already monitoring the name
    # carried by the payload. A missed rename with a registered hook does not
    # enter this path: `repository_link_for_hook_id` selects its secret, HMAC
    # verification succeeds, and the verified identity synchronizer repairs the
    # old link/channel names before dispatch. Without either a name match or a
    # recorded hook id there is no safe mapping from an unverified new name to
    # an old channel.
    #
    # The payload is UNVERIFIED here — that is the whole situation — so nothing
    # from it reaches the message. The repo name rendered is the channel's own
    # stored value, and a channel is only selected when that value already
    # equals the payload's. An attacker can therefore cause a canned warning in
    # topics that are already monitoring the repository they named, at most
    # once an hour each, and can inject no content of their own.
    def announce_webhook_auth_failure(payload)
      _id, repo = repository_identity(payload)
      return if repo.blank?

      claimed = Rails.cache.write(
        AUTH_FAILURE_SCAN_CACHE_KEY,
        true,
        expires_in: AUTH_FAILURE_SCAN_INTERVAL,
        unless_exist: true
      )
      return unless claimed

      GithubPrChannel.active.where("LOWER(repo_full_name) = ?", repo).find_each do |channel|
        begin
          channel.with_lock do
            last = channel.config["auth_failure_notified_at"]
            next if last.present? && Time.zone.parse(last) > AUTH_FAILURE_NOTICE_INTERVAL.ago

            # Marked before injecting: a failure while injecting must not leave
            # the channel free to retry the same warning on the next delivery,
            # which for a busy repo is seconds away.
            channel.update!(config: channel.config.merge("auth_failure_notified_at" => Time.current.iso8601))
            channel.inject_into_topic!(channel.auth_failure_message)
          end
        rescue => e
          Rails.logger.error(
            "[CollavreGithub] auth failure notice failed for channel #{channel.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end

    # Clear the marker once deliveries verify again, so a repository that
    # breaks, is repaired, then breaks again months later warns the second time
    # too. Left set, the interval above would be the only thing re-arming it.
    def clear_auth_failure_notices(payload)
      _id, repo = repository_identity(payload)
      return if repo.blank?

      GithubPrChannel.where("LOWER(repo_full_name) = ?", repo).find_each do |channel|
        next if channel.config["auth_failure_notified_at"].blank?

        begin
          channel.update!(config: channel.config.except("auth_failure_notified_at"))
        rescue => e
          Rails.logger.error(
            "[CollavreGithub] clearing auth failure notice failed for channel #{channel.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end

    def valid_signature?(raw_body)
      secret = webhook_secret
      signature_header = request.headers["X-Hub-Signature-256"] || request.headers["X-Hub-Signature"]

      if secret.blank?
        Rails.logger.warn("GitHub webhook secret missing; rejecting request")
        return false
      end

      return false if signature_header.blank?

      algorithm =
        if signature_header.start_with?("sha256=")
          "sha256"
        elsif signature_header.start_with?("sha1=")
          "sha1"
        end

      return false if algorithm.blank?

      digest = OpenSSL::HMAC.hexdigest(algorithm.upcase, secret, raw_body)
      expected_signature = "#{algorithm}=#{digest}"

      ActiveSupport::SecurityUtils.secure_compare(expected_signature, signature_header)
    end

    # Memoized: a rejected delivery reads this twice — once to verify, once to
    # decide whether the rejection is worth announcing — and the fallback path
    # queries integration settings.
    def webhook_secret
      return @webhook_secret if defined?(@webhook_secret)

      @webhook_secret = @repository_link&.webhook_secret || fallback_webhook_secret
    end

    def fallback_webhook_secret
      resolved =
        if defined?(Collavre::IntegrationSettings::Resolver)
          Collavre::IntegrationSettings::Resolver.get(:github_webhook_secret).presence
        end
      resolved || ENV["GITHUB_WEBHOOK_SECRET"] || Rails.application.credentials.dig(:github, :webhook_secret)
    end

    def parse_payload(raw_body)
      params = request.request_parameters
      parsed_params =
        case params
        when ActionController::Parameters
          params.to_unsafe_h
        else
          params
        end

      if parsed_params.present?
        wrapper_payload = parsed_params.with_indifferent_access[:payload]
        return wrapper_payload if wrapper_payload.is_a?(Hash)
        return JSON.parse(wrapper_payload) if wrapper_payload.is_a?(String)

        return parsed_params
      end

      raw_body.present? ? JSON.parse(raw_body) : nil
    end

    def github_event_header
      request.headers["X-GitHub-Event"].presence ||
        request.get_header("HTTP_X_GITHUB_EVENT").presence
    end

    def delivery_guid
      request.headers["X-GitHub-Delivery"].presence ||
        request.get_header("HTTP_X_GITHUB_DELIVERY").presence
    end
  end
end
