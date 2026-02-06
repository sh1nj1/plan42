module CollavreGithub
  require "sorbet-runtime"
  require "rails_mcp_engine"

  module Tools
    class GithubPrDetailsService
      extend T::Sig
      extend ToolMeta
      include Concerns::GithubClientFinder

      tool_name "github_pr_details"
      tool_description <<~DESC.strip
        Get details of a GitHub pull request including title, body, author, files changed, etc.
        Requires the creative to have a connected GitHub repository.
      DESC

      tool_param :creative_id, description: "The ID of the creative with GitHub integration."
      tool_param :repo, description: "Repository full name (e.g., 'owner/repo')."
      tool_param :pr_number, description: "Pull request number."

      sig { params(creative_id: Integer, repo: String, pr_number: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def call(creative_id:, repo:, pr_number:)
        client = find_github_client(creative_id, repo)
        return { error: "GitHub account not found for this creative and repository" } unless client

        pr = client.pull_request_details(repo, pr_number)
        return { error: "Pull request not found" } unless pr

        {
          number: pr.number,
          title: pr.title,
          body: pr.body.to_s.truncate(2000),
          state: pr.state,
          merged: pr.merged,
          author: pr.user&.login,
          created_at: pr.created_at&.iso8601,
          updated_at: pr.updated_at&.iso8601,
          merged_at: pr.merged_at&.iso8601,
          additions: pr.additions,
          deletions: pr.deletions,
          changed_files: pr.changed_files,
          html_url: pr.html_url,
          base_branch: pr.base&.ref,
          head_branch: pr.head&.ref
        }
      rescue StandardError => e
        { error: "Failed to fetch PR details: #{e.message}" }
      end
    end
  end
end
