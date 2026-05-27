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
      return head :unauthorized unless valid_signature?(raw_body)

      payload = payload.presence || {}

      # Process all links for this repo (same repo can be linked to multiple creatives)
      all_links = all_repository_links_for(payload)
      all_links.each do |link|
        create_system_comment_for(link, event, payload) if link.creative && !channel_only_event?(event)
        trigger_markdown_sync_for(link, event, payload) if link.markdown_sync_enabled?
      end

      maybe_auto_attach_channel(event, payload)
      dispatch_to_channels(event, payload)

      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

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
      body = payload.dig("pull_request", "body")
      topic_id = CollavreGithub::PrTopicLinkParser.call(body)
      return unless repo && pr_number && topic_id

      topic = Collavre::Topic.find_by(id: topic_id)
      return unless topic

      # Security: the PR description is attacker-controlled. Anyone able to open
      # a PR on this repo could otherwise drop a link to an unrelated tenant's
      # topic and have subsequent PR comments injected there. Only auto-attach
      # when the topic's creative — or any of its ancestors — is linked to this
      # repo (RepositoryLink applies to the whole subtree).
      linked_creative_ids = CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", repo).pluck(:creative_id)
      creative = topic.creative
      return unless creative
      candidate_ids = [ creative.id ] + creative.ancestors.pluck(:id)
      return if (linked_creative_ids & candidate_ids).empty?

      existing = GithubPrChannel.where(topic_id: topic.id).find do |c|
        c.repo_full_name.to_s.downcase == repo && c.pr_number == pr_number
      end
      if existing
        # Only `reopened` resurrects a dismissed/detached chip. A redelivered
        # `opened` webhook (GitHub retries 5xx, or duplicate fan-out) must NOT
        # undo a user's X dismissal — the PR was not actually reopened, and
        # silently bringing the chip back would defeat the dismissal UX. For
        # `opened` on an existing row we just no-op (idempotent redelivery).
        return existing unless payload["action"] == "reopened"

        # Row-level lock + re-read guards against duplicate reopened announcements
        # when two `pull_request.reopened` deliveries for the same dismissed/
        # detached channel arrive concurrently (GitHub retries on 5xx, or
        # duplicate fan-out). Without it, both requests can read was_inactive=true
        # before either clears dismissed_at, then both inject the reopened
        # message. Mirrors the close-path with_lock below.
        existing.with_lock do
          was_inactive = !existing.active? || !existing.dismissed_at.nil?
          if was_inactive || existing.pr_state != "open"
            existing.state = :active unless existing.active?
            existing.dismissed_at = nil unless existing.dismissed_at.nil?
            existing.pr_state = "open" if existing.pr_state != "open"
            existing.save!
          end
          # When the chip silently reappears after dismiss/detach, inject a
          # one-line announcement so the user can trace the lifecycle —
          # mirrors the attach announcement on first create.
          if was_inactive
            begin
              existing.inject_into_topic!(existing.reopened_message)
            rescue => e
              Rails.logger.error("[CollavreGithub] reopened announce failed: #{e.class}: #{e.message}")
            end
          end
        end
        return existing
      end
      GithubPrChannel.create!(
        topic_id: topic.id,
        config: { "repo_full_name" => repo, "pr_number" => pr_number, "pr_state" => "open" }
      )
    rescue ActiveRecord::RecordNotUnique
      # concurrent webhook safe
    rescue => e
      Rails.logger.error("[CollavreGithub] auto-attach failed: #{e.class}: #{e.message}")
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
      linked_creative_ids = CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", repo).pluck(:creative_id)

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

    def all_repository_links_for(payload)
      repo = payload&.dig("repository", "full_name") || payload&.dig(:repository, :full_name)
      return [ @repository_link ].compact if repo.blank?

      CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", repo.downcase)
        .to_a
    end

    def find_repository_link(payload)
      if payload.blank?
        Rails.logger.warn("[GitHub Webhook] Payload is blank")
        return
      end

      repo = payload["repository"] || payload[:repository]
      if repo.blank?
        Rails.logger.warn("[GitHub Webhook] Repository missing in payload")
        return
      end

      full_name = repo["full_name"] || repo[:full_name]
      if full_name.blank?
        Rails.logger.warn("[GitHub Webhook] Repository full_name missing in payload")
        return
      end

      CollavreGithub::RepositoryLink
        .where("LOWER(repository_full_name) = ?", full_name.downcase)
        .first
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

    def webhook_secret
      @repository_link&.webhook_secret || fallback_webhook_secret
    end

    def fallback_webhook_secret
      ENV["GITHUB_WEBHOOK_SECRET"] || Rails.application.credentials.dig(:github, :webhook_secret)
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
  end
end
