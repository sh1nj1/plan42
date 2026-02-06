# frozen_string_literal: true

require "test_helper"

module CollavreGithub
  module Tools
    class GithubPrCommitsServiceTest < ActiveSupport::TestCase
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
        service = GithubPrCommitsService.new
        result = service.call(creative_id: 999999, repo: "owner/repo", pr_number: 1)

        assert_equal "GitHub account not found for this creative and repository", result[:error]
      end

      test "returns error when repository link not found for different repo" do
        service = GithubPrCommitsService.new
        result = service.call(creative_id: @creative.id, repo: "other/repo", pr_number: 1)

        assert_equal "GitHub account not found for this creative and repository", result[:error]
      end

      test "finds github client for valid creative and repo" do
        service = GithubPrCommitsService.new

        client = service.send(:find_github_client, @creative.id, "owner/repo")

        assert_not_nil client
        assert_instance_of CollavreGithub::Client, client
      end
    end
  end
end
