# frozen_string_literal: true

require "test_helper"

module CollavreGithub
  module Tools
    class GithubPrDetailsServiceTest < ActiveSupport::TestCase
      SERVICE_CLASS = GithubPrDetailsService
      include GithubPrServiceTestSetup

      test "returns nil client when repository not in creative tree" do
        other_creative = Collavre::Creative.create!(
          user: @user,
          description: "Unrelated creative"
        )

        service = GithubPrDetailsService.new
        client = service.send(:find_github_client, other_creative.id, "owner/repo")

        assert_nil client
      end
    end
  end
end
