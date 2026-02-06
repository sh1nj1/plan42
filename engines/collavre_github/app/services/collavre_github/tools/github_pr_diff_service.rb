# frozen_string_literal: true

require "sorbet-runtime"
require "rails_mcp_engine"

module CollavreGithub
  module Tools
    class GithubPrDiffService
      extend T::Sig
      extend ToolMeta
      include Concerns::GithubClientFinder

      DIFF_MAX_LENGTH = 10_000

      tool_name "github_pr_diff"
      tool_description <<~DESC.strip
        Get the diff of a GitHub pull request.
        Returns the patch/diff for all changed files.
        Requires the creative to have a connected GitHub repository.
      DESC

      tool_param :creative_id, description: "The ID of the creative with GitHub integration."
      tool_param :repo, description: "Repository full name (e.g., 'owner/repo')."
      tool_param :pr_number, description: "Pull request number."
      tool_param :max_length, description: "Maximum diff length (default: 10000 chars).", required: false

      sig do
        params(
          creative_id: Integer,
          repo: String,
          pr_number: Integer,
          max_length: T.nilable(Integer)
        ).returns(T::Hash[Symbol, T.untyped])
      end
      def call(creative_id:, repo:, pr_number:, max_length: nil)
        max_length ||= DIFF_MAX_LENGTH

        client = find_github_client(creative_id, repo)
        return { error: "GitHub account not found for this creative and repository" } unless client

        diff = client.pull_request_diff(repo, pr_number)
        return { error: "Could not fetch diff", diff: nil } unless diff

        truncated = diff.length > max_length
        diff_text = truncated ? "#{diff[0, max_length]}\n...\n[Diff truncated to #{max_length} characters]" : diff

        {
          diff: diff_text,
          truncated: truncated,
          original_length: diff.length
        }
      rescue StandardError => e
        { error: "Failed to fetch PR diff: #{e.message}" }
      end
    end
  end
end
