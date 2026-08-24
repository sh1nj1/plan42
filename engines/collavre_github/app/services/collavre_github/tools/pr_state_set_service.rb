# frozen_string_literal: true

require "sorbet-runtime"
require "rails_mcp_engine"

module CollavreGithub
  module Tools
    class PrStateSetService
      extend T::Sig
      extend ToolMeta
      include Concerns::PrChannelLocator

      tool_name "pr_state_set"
      tool_description <<~DESC.strip
        Correct the state of a GitHub PR channel attached with pr_monitor, for
        when a `pull_request` webhook was missed (hook added after the merge,
        delivery failure) and the chip is stuck on the wrong badge.

        Omit `state` to resynchronize from the GitHub API — that is the
        preferred form, because it cannot record a state the PR does not
        actually have. Pass `state` explicitly only as a fallback when no
        GitHub account is connected for the repository.

        Closing the channel (merged / closed_without_merge) posts the closing
        message and detaches it; reopening it resumes monitoring. Idempotent.
      DESC

      tool_param :topic_id, description: "The Collavre topic id the PR channel is attached to."
      tool_param :pr_url, description: "Full GitHub PR URL, e.g. https://github.com/owner/repo/pull/123"
      tool_param :state,
        description: "Target state. Omit to read the real state from GitHub.",
        required: false,
        enum: CollavreGithub::GithubPrChannel::PR_STATES

      sig do
        params(
          topic_id: Integer,
          pr_url: String,
          state: T.nilable(String)
        ).returns(T::Hash[Symbol, T.untyped])
      end
      def call(topic_id:, pr_url:, state: nil)
        repo, pr_number = parse_pr_url(pr_url)

        topic = Collavre::Topic.find(topic_id)
        Collavre::Tools::TopicAuthorizer.authorize_write!(topic)

        channel = lookup_channel(topic, repo, pr_number)
        unless channel
          return {
            ok: false,
            error: "No PR channel for #{repo}##{pr_number} on topic #{topic_id}. Attach it with pr_monitor first."
          }
        end

        target, source = resolve_state(topic, repo, pr_number, state)
        return target if target.is_a?(Hash) # error payload

        result = CollavreGithub::PrChannelStateUpdater.call(channel: channel, state: target)
        {
          ok: true,
          channel_id: channel.id,
          repo: repo,
          pr_number: pr_number,
          pr_state: target,
          previous_state: result.previous_state,
          status: result.status.to_s,
          state_source: source
        }
      end

      private

      # Returns [state, source] or an error hash. An explicit `state` is
      # validated here rather than at the updater so a typo surfaces as an
      # ArgumentError naming the tool parameter the caller actually passed.
      sig do
        params(
          topic: Collavre::Topic,
          repo: String,
          pr_number: Integer,
          state: T.nilable(String)
        ).returns([ T.any(String, T::Hash[Symbol, T.untyped]), String ])
      end
      def resolve_state(topic, repo, pr_number, state)
        if state.present?
          unless CollavreGithub::GithubPrChannel::PR_STATES.include?(state)
            raise ArgumentError,
              "Invalid state: #{state.inspect} (expected one of #{CollavreGithub::GithubPrChannel::PR_STATES.join(', ')})"
          end
          return [ state, "explicit" ]
        end

        clients = verified_github_clients_for(topic, repo)
        if clients.empty?
          return [ {
            ok: false,
            error: "No verified connected GitHub account for #{repo} in this topic's creative scope, " \
                   "so the state could not be read from GitHub. Pass `state` explicitly instead."
          }, "github" ]
        end

        clients.each do |client|
          remote = remote_state(client, repo, pr_number)
          return [ remote, "github" ] if remote
        end

        [ {
          ok: false,
          error: "Could not read #{repo}##{pr_number} from GitHub (not found, or the API call failed). " \
                 "Pass `state` explicitly instead."
        }, "github" ]
      end

      # GitHub reports merge and closure separately: `merged` is the
      # authoritative merge flag, and `state` only distinguishes open from
      # closed. Checking `merged` first is what keeps a squash-merged PR from
      # being recorded as closed_without_merge.
      def remote_state(client, repo, pr_number)
        pr = client.pull_request_details(repo, pr_number)
        return nil unless pr
        return "merged" if pr.merged

        pr.state.to_s == "closed" ? "closed_without_merge" : "open"
      end

      # A repository name is not an identity: GitHub can reuse it after a
      # rename. Keep only accounts whose live repository id matches a stable id
      # stored on an in-scope RepositoryLink, then let resync try each account
      # until one can read the PR.
      def verified_github_clients_for(topic, repo)
        candidate_ids = scoped_creative_ids(topic)
        return [] if candidate_ids.empty?

        links = CollavreGithub::RepositoryLink
          .where("LOWER(repository_full_name) = ?", repo.downcase)
          .where(creative_id: candidate_ids)
          .where.not(repository_id: nil)
          .order(:id)
          .to_a

        links.group_by(&:github_account_id).filter_map do |account_id, account_links|
          verified_client_for(account_id, account_links, repo)
        end
      end

      def verified_client_for(account_id, links, repo)
        client = CollavreGithub::Client.new(links.first.github_account)
        identity = client.repository_identity(repo)
        return client if links.any? { |link| link.repository_id.to_s == identity.id.to_s }

        nil
      rescue Octokit::Error, Faraday::Error => e
        Rails.logger.warn(
          "[pr_state_set] repository identity lookup failed for #{repo} through " \
          "account #{account_id}: #{e.class}: #{e.message}"
        )

        nil
      end
    end
  end
end
