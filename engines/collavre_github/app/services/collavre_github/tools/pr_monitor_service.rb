# frozen_string_literal: true

require "sorbet-runtime"
require "rails_mcp_engine"

module CollavreGithub
  module Tools
    class PrMonitorService
      extend T::Sig
      extend ToolMeta

      PR_URL_RE = %r{\Ahttps?://github\.com/([^/]+/[^/]+)/pull/(\d+)\z}.freeze

      tool_name "pr_monitor"
      tool_description <<~DESC.strip
        Attach a GitHub PR monitor to a Collavre topic. After attachment,
        PR comments, review comments, and review submissions are injected
        into the topic as chat messages. Idempotent.
      DESC

      tool_param :topic_id, description: "The Collavre topic id to attach the PR channel to."
      tool_param :pr_url, description: "Full GitHub PR URL, e.g. https://github.com/owner/repo/pull/123"

      sig { params(topic_id: Integer, pr_url: String).returns(T::Hash[Symbol, T.untyped]) }
      def call(topic_id:, pr_url:)
        m = pr_url.match(PR_URL_RE)
        raise ArgumentError, "Invalid PR URL: #{pr_url}" unless m
        # GitHub owner/repo identifiers are case-insensitive but webhook payloads
        # always carry the canonical case. Normalize on store so user input
        # like "Owner/Repo" still matches incoming events.
        repo = m[1].downcase
        pr_number = m[2].to_i

        topic = Collavre::Topic.find(topic_id)
        authorize_topic_write!(topic)
        channel, attach_status = find_or_attach_channel(topic, repo, pr_number)
        # Re-seed announcement on fresh attach AND on detached->active so the
        # chip label/link cache is repopulated after the channel was previously
        # auto-detached (PR closed) and the user reattached it.
        if attach_status == :created || attach_status == :reactivated
          channel.inject_into_topic!(channel.attached_message)
        end

        result = { ok: true, channel_id: channel.id, repo: repo, pr_number: pr_number }
        warning = ensure_webhook_events(topic, repo)
        result[:webhook_warning] = warning if warning
        result
      end

      private

      # Attaching a channel injects external messages into the topic, so it is a
      # write-equivalent mutation. Mirror CreativePermissionGuard#require_creative_write!
      # against the topic's effective_origin so MCP callers cannot drop monitors
      # onto topics they would not be allowed to comment on.
      def authorize_topic_write!(topic)
        creative = topic.creative&.effective_origin
        raise ArgumentError, "Topic has no creative" unless creative

        user = Collavre::Current.user
        return if creative.user == user
        return if user && creative.has_permission?(user, :write)

        raise CollavreGithub::Tools::PermissionDeniedError,
          "No write permission on topic #{topic.id}"
      end

      # Returns the channel plus a status symbol so callers can distinguish:
      #   :created     - new row inserted
      #   :reactivated - existing detached row flipped back to active
      #   :noop        - row was already active (idempotent re-attach)
      sig { params(topic: Collavre::Topic, repo: String, pr_number: Integer).returns([ CollavreGithub::GithubPrChannel, Symbol ]) }
      def find_or_attach_channel(topic, repo, pr_number)
        existing = lookup_channel(topic, repo, pr_number)
        if existing
          return [ existing, :noop ] if existing.active? && existing.dismissed_at.nil?
          reactivate!(existing)
          return [ existing, :reactivated ]
        end
        created = CollavreGithub::GithubPrChannel.create!(
          topic_id: topic.id,
          config: { "repo_full_name" => repo, "pr_number" => pr_number, "pr_state" => "open" }
        )
        [ created, :created ]
      rescue ActiveRecord::RecordNotUnique
        # Concurrent caller won the race; reuse the row they created.
        existing = lookup_channel(topic, repo, pr_number)
        raise unless existing
        if existing.active? && existing.dismissed_at.nil?
          [ existing, :noop ]
        else
          reactivate!(existing)
          [ existing, :reactivated ]
        end
      end

      # Mirror WebhooksController#maybe_auto_attach_channel reactivation: clear
      # dismissed_at and reset pr_state so the chip surfaces again under the
      # not_dismissed render scope. Otherwise pr_monitor would report success
      # and inject the attached message while the chip stayed hidden.
      def reactivate!(channel)
        channel.state = :active unless channel.active?
        channel.dismissed_at = nil unless channel.dismissed_at.nil?
        channel.pr_state = "open" if channel.pr_state != "open"
        channel.save!
      end

      sig { params(topic: Collavre::Topic, repo: String, pr_number: Integer).returns(T.nilable(CollavreGithub::GithubPrChannel)) }
      def lookup_channel(topic, repo, pr_number)
        CollavreGithub::GithubPrChannel.where(topic_id: topic.id).find do |c|
          c.repo_full_name.to_s.downcase == repo.downcase && c.pr_number == pr_number
        end
      end

      # Make sure the repo's webhook subscribes to the PR-channel events
      # (issue_comment / pull_request_review / pull_request_review_comment).
      # Without these, GitHub never delivers comment payloads and the channel
      # silently misses them — exactly the bug that motivated this method.
      # Returns a warning string when provisioning cannot run or fails; nil on
      # success so the MCP response stays clean.
      def ensure_webhook_events(topic, repo)
        scoped_link = scoped_repository_link_for(topic, repo)
        return "no RepositoryLink found for #{repo} in topic creative scope; webhook events not auto-provisioned" unless scoped_link

        # Provision through the *global* primary link (lowest id across all
        # creatives), not the scoped link. WebhookProvisioner only patches hook
        # events when the link IS the primary; non-primary links short-circuit
        # to secret alignment and skip the GitHub edit_hook call. So if we
        # provisioned the scoped link and it was not the global primary, the
        # existing hook would keep its old event list. The scoped link is only
        # used as an authorization gate above.
        provisioning_link = global_primary_repository_link_for(repo) || scoped_link

        account = provisioning_link.github_account
        return "RepositoryLink for #{repo} has no GitHub account; webhook events not auto-provisioned" unless account

        results = CollavreGithub::WebhookProvisioner.ensure_for_links(
          account: account,
          links: [ provisioning_link ],
          webhook_url: github_webhook_url
        )
        status = results.first&.last
        # :failed means Client returned nil (Octokit/Faraday error rescued in
        # CollavreGithub::Client). Surface that to the MCP caller so they know
        # webhook events were not actually patched.
        return "webhook provisioning failed: GitHub API rejected the hook request (see logs)" if status == :failed
        nil
      rescue => e
        Rails.logger.warn("[pr_monitor] webhook provisioning failed for #{repo}: #{e.class}: #{e.message}")
        "webhook provisioning failed: #{e.message}"
      end

      # Authorization gate: a RepositoryLink for `repo` must live in this
      # topic's creative subtree (the topic creative itself or one of its
      # ancestors). Without one, the dispatch path in WebhooksController would
      # silently drop events for this topic anyway.
      def scoped_repository_link_for(topic, repo)
        creative = topic.creative
        return nil unless creative

        candidate_ids = [ creative.id ] + creative.ancestors.pluck(:id)
        CollavreGithub::RepositoryLink
          .where("LOWER(repository_full_name) = ?", repo.downcase)
          .where(creative_id: candidate_ids)
          .order(:id)
          .first
      end

      # Mirrors WebhookProvisioner#primary_link_for: the lowest-id link for the
      # repo across ALL creatives. This is the link whose secret + events the
      # hook is aligned to, so we must provision through it to trigger an
      # actual edit_hook call.
      def global_primary_repository_link_for(repo)
        CollavreGithub::RepositoryLink
          .where("LOWER(repository_full_name) = ?", repo.downcase)
          .order(:id)
          .first
      end

      def github_webhook_url
        CollavreGithub::Engine.routes.url_helpers.webhooks_url(
          Rails.application.config.action_mailer.default_url_options
        )
      end
    end
  end
end
