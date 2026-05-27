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
        channel, created = find_or_attach_channel(topic, repo, pr_number)
        channel.inject_into_topic!(channel.attached_message) if created
        { ok: true, channel_id: channel.id, repo: repo, pr_number: pr_number }
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

      sig { params(topic: Collavre::Topic, repo: String, pr_number: Integer).returns([ CollavreGithub::GithubPrChannel, T::Boolean ]) }
      def find_or_attach_channel(topic, repo, pr_number)
        existing = lookup_channel(topic, repo, pr_number)
        if existing
          existing.update!(state: :active) unless existing.active?
          return [ existing, false ]
        end
        created = CollavreGithub::GithubPrChannel.create!(
          topic_id: topic.id,
          config: { "repo_full_name" => repo, "pr_number" => pr_number }
        )
        [ created, true ]
      rescue ActiveRecord::RecordNotUnique
        # Concurrent caller won the race; reuse the row they created.
        existing = lookup_channel(topic, repo, pr_number)
        raise unless existing
        existing.update!(state: :active) unless existing.active?
        [ existing, false ]
      end

      sig { params(topic: Collavre::Topic, repo: String, pr_number: Integer).returns(T.nilable(CollavreGithub::GithubPrChannel)) }
      def lookup_channel(topic, repo, pr_number)
        CollavreGithub::GithubPrChannel.where(topic_id: topic.id).find do |c|
          c.repo_full_name.to_s.downcase == repo.downcase && c.pr_number == pr_number
        end
      end
    end
  end
end
