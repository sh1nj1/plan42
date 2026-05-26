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
        repo = m[1]
        pr_number = m[2].to_i

        topic = Collavre::Topic.find(topic_id)
        existing = CollavreGithub::GithubPrChannel.where(topic_id: topic.id).find do |c|
          c.repo_full_name == repo && c.pr_number == pr_number
        end
        channel = existing || CollavreGithub::GithubPrChannel.create!(
          topic_id: topic.id,
          config: { "repo_full_name" => repo, "pr_number" => pr_number }
        )
        { ok: true, channel_id: channel.id, repo: repo, pr_number: pr_number }
      end
    end
  end
end
