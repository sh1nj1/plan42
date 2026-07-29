require_relative "../../test_helper"

module CollavreGithub
  class WebhookReprovisionerTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @account = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "reprovisioner",
        login: "reprovisioner",
        name: "Reprovisioner",
        token: "test-token"
      )
      @primary = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:tshirt),
        github_account: @account,
        repository_full_name: "Owner/Repo"
      )
      @sibling = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: "owner/repo"
      )
      @other = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: "owner/other"
      )
    end

    test "reprovisions every existing repository once through its primary link" do
      calls = []
      provision = lambda do |account:, links:, webhook_url:|
        calls << { account: account, links: links, webhook_url: webhook_url }
        [ [ links.first, :updated ] ]
      end

      results = CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
      end

      assert_equal [ [ "owner/other", :updated ], [ "owner/repo", :updated ] ], results
      assert_equal [ @other, @primary ], calls.map { |call| call[:links].first }
      assert calls.all? { |call| call[:account] == @account }
      assert calls.all? { |call| call[:webhook_url] == "https://example.com/github/webhooks" }
      assert_not_includes calls.map { |call| call[:links].first }, @sibling
    end

    test "reports a failed repository and continues reprovisioning the rest" do
      provision = lambda do |account:, links:, webhook_url:|
        status = links.first == @other ? :failed : :updated
        [ [ links.first, status ] ]
      end

      results = CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
      end

      assert_equal [ [ "owner/other", :failed ], [ "owner/repo", :updated ] ], results
    end
  end
end
