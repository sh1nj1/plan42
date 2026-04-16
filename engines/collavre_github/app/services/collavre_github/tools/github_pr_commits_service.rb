# frozen_string_literal: true

require "sorbet-runtime"
require "rails_mcp_engine"

module CollavreGithub
  module Tools
    class GithubPrCommitsService
      extend T::Sig
      extend ToolMeta
      include Concerns::GithubClientFinder

      tool_name "github_pr_commits"
      tool_description <<~DESC.strip
        Get the commit messages of a GitHub pull request.
        Returns a list of commit messages in the PR.
        Requires the creative to have a connected GitHub repository.
      DESC

      tool_param :creative_id, description: "The ID of the creative with GitHub integration."
      tool_param :repo, description: "Repository full name (e.g., 'owner/repo')."
      tool_param :pr_number, description: "Pull request number."

      sig { params(creative_id: Integer, repo: String, pr_number: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def call(creative_id:, repo:, pr_number:)
        with_github_client(creative_id: creative_id, repo: repo, error_context: "fetch PR commits") do |client|
          messages = client.pull_request_commit_messages(repo, pr_number)

          {
            commits: messages.map.with_index(1) { |msg, i| { index: i, message: msg } },
            count: messages.size
          }
        end
      end
    end
  end
end
