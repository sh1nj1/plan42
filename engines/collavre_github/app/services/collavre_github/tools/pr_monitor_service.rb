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
        Collavre::Tools::TopicAuthorizer.authorize_write!(topic)
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

      # Wraps Collavre::ChannelAttacher with PR-specific create attrs and a
      # PR-specific reactivation reset (pr_state back to "open"). The shared
      # attacher handles the create/reactivate/noop lifecycle, including the
      # concurrent insert race and dismissed_at clearing — Mirror
      # WebhooksController#maybe_auto_attach_channel reactivation, so the
      # chip resurfaces under the not_dismissed render scope.
      sig { params(topic: Collavre::Topic, repo: String, pr_number: Integer).returns([ CollavreGithub::GithubPrChannel, Symbol ]) }
      def find_or_attach_channel(topic, repo, pr_number)
        Collavre::ChannelAttacher.call(
          channel_class: CollavreGithub::GithubPrChannel,
          lookup: -> { lookup_channel(topic, repo, pr_number) },
          create_attrs: {
            topic_id: topic.id,
            config: { "repo_full_name" => repo, "pr_number" => pr_number, "pr_state" => "open" }
          },
          on_reactivate: ->(channel) {
            channel.pr_state = "open" if channel.pr_state != "open"
          }
        )
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
        scoped_link = verified_scoped_repository_link_for(topic, repo)
        unless scoped_link
          return "no verified RepositoryLink found for #{repo} in topic creative scope; " \
                 "webhook events not auto-provisioned"
        end

        results = CollavreGithub::WebhookProvisioner.ensure_for_links(
          account: scoped_link.github_account,
          links: [ scoped_link ],
          webhook_url: github_webhook_url,
          force_hook_refresh: true
        )
        status = results.first&.last
        # :failed means Client returned nil (Octokit/Faraday error rescued in
        # CollavreGithub::Client). Surface that to the MCP caller so they know
        # webhook events were not actually patched.
        return "webhook provisioning failed: GitHub API rejected the hook request (see logs)" if status == :failed
        # :shared is NOT a warning. It means a hook registered in this database
        # already exists, so this instance reused it instead of adding a second
        # one, and its events and secret have been patched from here — a patch
        # that fails comes back as :failed and is reported above. (The other
        # route to :shared is losing the creation race to a sibling, whose hook
        # was just built from these same RepositoryLink rows, so its
        # subscriptions are current by construction.) Only the hook's URL is
        # left pointing at the sibling, which pr_monitor does not depend on.
        # Warning here reported a provisioning problem where there is none.
        nil
      rescue => e
        Rails.logger.warn("[pr_monitor] webhook provisioning failed for #{repo}: #{e.class}: #{e.message}")
        "webhook provisioning failed: #{e.message}"
      end

      # Authorization and identity gate: a RepositoryLink for `repo` must live
      # in this topic's creative subtree, carry a stable repository id, and
      # resolve to that same id through its GitHub account. A stored name alone
      # is not safe provisioning evidence because GitHub can reuse a renamed
      # repository's old name.
      def verified_scoped_repository_link_for(topic, repo)
        creative = topic.creative
        return nil unless creative

        candidate_ids = [ creative.id ] + creative.ancestors.pluck(:id)
        candidates = CollavreGithub::RepositoryLink
          .where("LOWER(repository_full_name) = ?", repo.downcase)
          .where(creative_id: candidate_ids)
          .order(:id)
          .to_a
        identities = {}

        candidates.find do |link|
          account = link.github_account
          next false if link.repository_id.blank? || account.nil?

          identity = identities.fetch(account.id) do
            identities[account.id] = CollavreGithub::Client.new(account).repository_identity(repo)
          rescue Octokit::Error, Faraday::Error => e
            Rails.logger.warn(
              "[pr_monitor] repository identity lookup failed for #{repo} through " \
              "account #{account.id}: #{e.class}: #{e.message}"
            )
            identities[account.id] = nil
          end
          identity&.id.to_s == link.repository_id.to_s
        end
      end

      def github_webhook_url
        CollavreGithub::Engine.routes.url_helpers.webhooks_url(
          Rails.application.config.action_mailer.default_url_options
        )
      end
    end
  end
end
