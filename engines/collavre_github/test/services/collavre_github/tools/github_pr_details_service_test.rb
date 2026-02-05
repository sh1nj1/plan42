require "test_helper"

module CollavreGithub
  module Tools
    class GithubPrDetailsServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @account = CollavreGithub::Account.create!(
          user: @user,
          github_uid: "12345",
          login: "testuser",
          name: "Test User",
          token: "test-token"
        )
        @creative = creatives(:tshirt)
        @link = CollavreGithub::RepositoryLink.create!(
          creative: @creative,
          github_account: @account,
          repository_full_name: "owner/repo"
        )
      end

      test "returns error when creative not found" do
        service = GithubPrDetailsService.new
        result = service.call(creative_id: 999999, repo: "owner/repo", pr_number: 1)

        assert_equal "GitHub account not found for this creative and repository", result[:error]
      end

      test "returns error when repository link not found for different repo" do
        service = GithubPrDetailsService.new
        result = service.call(creative_id: @creative.id, repo: "other/repo", pr_number: 1)

        assert_equal "GitHub account not found for this creative and repository", result[:error]
      end

      test "finds github client for valid creative and repo" do
        service = GithubPrDetailsService.new

        # Access private method to test client lookup
        client = service.send(:find_github_client, @creative.id, "owner/repo")

        assert_not_nil client
        assert_instance_of CollavreGithub::Client, client
      end

      test "returns nil client when repository not in creative tree" do
        # Create unrelated creative without link
        other_creative = Collavre::Creative.create!(
          user: @user,
          description: "Unrelated creative"
        )

        service = GithubPrDetailsService.new
        client = service.send(:find_github_client, other_creative.id, "owner/repo")

        # Should return nil because other_creative has no link to owner/repo
        assert_nil client
      end
    end
  end
end
