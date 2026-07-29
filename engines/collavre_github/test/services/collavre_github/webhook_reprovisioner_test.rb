require_relative "../../test_helper"

module CollavreGithub
  class WebhookReprovisionerTest < ActiveSupport::TestCase
    Hook = Struct.new(:id)
    RepositoryIdentity = Struct.new(:id, :full_name)

    class IdentityClient
      attr_reader :repository_names

      def initialize(hooks:, repository_id:, repository_full_name: nil)
        @hooks = hooks
        @repository_id = repository_id
        @repository_full_name = repository_full_name
        @repository_names = []
      end

      def repository_hooks!(repository_name)
        @repository_names << repository_name
        @hooks
      end

      def repository_identity(repository_name)
        @repository_names << repository_name
        repository_id = configured_value(@repository_id, repository_name)
        full_name = configured_value(@repository_full_name, repository_name) || repository_name
        RepositoryIdentity.new(repository_id, full_name)
      end

      private

      def configured_value(value, repository_name)
        value.is_a?(Hash) ? value.fetch(repository_name.downcase) : value
      end
    end

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
        repository_full_name: "Owner/Repo",
        repository_id: 101
      )
      @sibling = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: "owner/repo",
        repository_id: 101
      )
      @other = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: "owner/other",
        repository_id: 202
      )
    end

    test "reprovisions every existing repository once through its primary link" do
      calls = []
      provision = lambda do |account:, links:, webhook_url:|
        calls << { account: account, links: links, webhook_url: webhook_url }
        [ [ links.first, :updated ] ]
      end

      client = IdentityClient.new(
        hooks: [],
        repository_id: { "owner/other" => 202, "owner/repo" => 101 }
      )
      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
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

      client = IdentityClient.new(
        hooks: [],
        repository_id: { "owner/other" => 202, "owner/repo" => 101 }
      )
      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :failed ], [ "owner/repo", :updated ] ], results
    end

    test "reprovisions a name-only legacy repository after its registered hook proves identity" do
      @other.update_column(:repository_id, nil)
      @other.update_column(:webhook_hook_id, 77)
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end
      client = IdentityClient.new(
        hooks: [ Hook.new(77) ],
        repository_id: { "owner/other" => 202, "owner/repo" => 101 }
      )

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :updated ], [ "owner/repo", :updated ] ], results
      assert_equal [ @other, @primary ], calls.map { |call| call[:links].first }
      assert_equal 202, @other.reload.repository_id
      assert_equal [ "owner/other", "owner/other", "Owner/Repo" ], client.repository_names
    end

    test "persists the canonical repository name and renames channels during legacy reconciliation" do
      @primary.destroy!
      @sibling.destroy!
      @other.update_columns(repository_id: nil, webhook_hook_id: 77)
      topic = Collavre::Topic.create!(creative: @other.creative, user: @user, name: "Legacy")
      channel = GithubPrChannel.create!(
        topic: topic,
        config: { "repo_full_name" => "owner/other", "pr_number" => 9 }
      )
      client = IdentityClient.new(
        hooks: [ Hook.new(77) ],
        repository_id: 202,
        repository_full_name: "owner/renamed"
      )
      provision = lambda do |**kwargs|
        assert_equal "owner/renamed", kwargs[:links].first.repository_full_name
        [ [ kwargs[:links].first, :updated ] ]
      end

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :updated ] ], results
      assert_equal 202, @other.reload.repository_id
      assert_equal "owner/renamed", @other.repository_full_name
      assert_equal "owner/renamed", channel.reload.repo_full_name
    end

    test "skips an ID-backed stale name that now resolves to another repository" do
      @primary.destroy!
      @sibling.destroy!
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end
      client = IdentityClient.new(hooks: [], repository_id: 999)

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :skipped_unverified ] ], results
      assert_empty calls
      assert_equal 202, @other.reload.repository_id
      assert_equal "owner/other", @other.repository_full_name
    end

    test "skips a name-only legacy repository with no registered hook" do
      @other.update_columns(repository_id: nil, webhook_hook_id: nil)
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end

      client = IdentityClient.new(hooks: [], repository_id: 101)
      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :skipped_unverified ], [ "owner/repo", :updated ] ], results
      assert_equal [ @primary ], calls.map { |call| call[:links].first }
      assert_nil @other.reload.repository_id
    end

    test "skips a stale legacy name when the current repository does not own the registered hook" do
      @other.update_columns(repository_id: nil, webhook_hook_id: 77)
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end
      client = IdentityClient.new(
        hooks: [ Hook.new(88) ],
        repository_id: { "owner/other" => 999, "owner/repo" => 101 }
      )

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :skipped_unverified ], [ "owner/repo", :updated ] ], results
      assert_equal [ @primary ], calls.map { |call| call[:links].first }
      assert_nil @other.reload.repository_id
      assert_equal [ "owner/other", "Owner/Repo" ], client.repository_names
    end
  end
end
