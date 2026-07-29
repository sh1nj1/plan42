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
      provision = lambda do |account:, links:, webhook_url:, force_hook_refresh:|
        calls << {
          account: account,
          links: links,
          webhook_url: webhook_url,
          force_hook_refresh: force_hook_refresh
        }
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
      assert calls.all? { |call| call[:force_hook_refresh] }
      assert_not_includes calls.map { |call| call[:links].first }, @sibling
    end

    test "reports a failed repository and continues reprovisioning the rest" do
      provision = lambda do |account:, links:, webhook_url:, force_hook_refresh:|
        assert force_hook_refresh
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

    test "skips a name-only legacy repository even when its registered hook is live" do
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

      assert_equal [ [ "owner/other", :manual_verification_required ], [ "owner/repo", :updated ] ], results
      assert_equal [ @primary ], calls.map { |call| call[:links].first }
      assert_nil @other.reload.repository_id
      assert_equal [ "Owner/Repo" ], client.repository_names
    end

    test "does not treat a copied legacy hook registration as repository identity" do
      @primary.destroy!
      @sibling.destroy!
      @other.destroy!
      contaminated = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:tshirt),
        github_account: @account,
        repository_full_name: "owner/reused",
        repository_id: nil,
        webhook_hook_id: 77,
        webhook_secret: "shared-secret"
      )
      valid = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: "owner/reused",
        repository_id: 222,
        webhook_hook_id: 77,
        webhook_secret: "shared-secret"
      )
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end
      client = IdentityClient.new(
        hooks: [ Hook.new(77) ],
        repository_id: 222
      )

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/reused", :manual_verification_required ] ], results
      assert_equal [ valid ], calls.map { |call| call[:links].first }
      assert_nil contaminated.reload.repository_id
      assert_equal "owner/reused", contaminated.repository_full_name
    end

    test "reports a failed ID-backed candidate when its same-name legacy row also needs verification" do
      legacy = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:root_parent),
        github_account: @account,
        repository_full_name: "owner/repo",
        repository_id: nil,
        webhook_hook_id: @primary.webhook_hook_id,
        webhook_secret: @primary.webhook_secret
      )
      client = IdentityClient.new(hooks: [], repository_id: 101)
      provision = ->(**kwargs) { [ [ kwargs[:links].first, :failed ] ] }

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal :failed, results.assoc("owner/repo").last
      assert_nil legacy.reload.repository_id
    end

    test "persists the canonical repository name and renames channels during reconciliation" do
      @primary.destroy!
      @sibling.destroy!
      @other.update_column(:webhook_hook_id, 77)
      topic = Collavre::Topic.create!(creative: @other.creative, user: @user, name: "Legacy")
      channel = GithubPrChannel.create!(
        topic: topic,
        config: { "repo_full_name" => "owner/other", "pr_number" => 9 }
      )
      child = Collavre::Creative.create!(parent: @other.creative, user: @user, description: "Child")
      CollavreGithub::RepositoryLink.create!(
        creative: child,
        github_account: @account,
        repository_full_name: "owner/other",
        repository_id: 999
      )
      child_topic = Collavre::Topic.create!(creative: child, user: @user, name: "Conflicting repository")
      child_channel = GithubPrChannel.create!(
        topic: child_topic,
        config: { "repo_full_name" => "owner/other", "pr_number" => 10 }
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
      assert_equal "owner/other", child_channel.reload.repo_full_name
    end

    test "merges an old-name channel when the canonical channel already exists" do
      @primary.destroy!
      @sibling.destroy!
      topic = Collavre::Topic.create!(creative: @other.creative, user: @user, name: "Duplicate")
      obsolete = GithubPrChannel.create!(
        topic: topic,
        config: { "repo_full_name" => "owner/other", "pr_number" => 9 }
      )
      survivor = GithubPrChannel.create!(
        topic: topic,
        config: {
          "repo_full_name" => "OWNER/RENAMED",
          "pr_number" => 9,
          "ignore_actor_logins" => [ "existing-bot" ]
        }
      )
      client = IdentityClient.new(
        hooks: [],
        repository_id: 202,
        repository_full_name: "owner/renamed"
      )
      provision = ->(**kwargs) { [ [ kwargs[:links].first, :updated ] ] }

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/other", :updated ] ], results
      assert_not GithubPrChannel.exists?(obsolete.id)
      assert GithubPrChannel.exists?(survivor.id)
      assert_equal [ survivor.id ],
        GithubPrChannel.where(topic: topic, repo_full_name: "owner/renamed", pr_number: 9).pluck(:id)
      assert_equal [ "existing-bot" ], survivor.reload.config["ignore_actor_logins"]
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

    test "tries later same-name links when the first ID-backed candidate is stale" do
      @primary.destroy!
      @sibling.destroy!
      @other.destroy!
      stale = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:tshirt),
        github_account: @account,
        repository_full_name: "owner/shared",
        repository_id: 111
      )
      valid = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: @account,
        repository_full_name: "owner/shared",
        repository_id: 222
      )
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end
      client = IdentityClient.new(hooks: [], repository_id: 222)

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/shared", :updated ] ], results
      assert_equal [ valid ], calls.map { |call| call[:links].first }
      assert_equal 111, stale.reload.repository_id
    end

    test "tries a later account when an identity-valid candidate cannot update the hook" do
      @primary.destroy!
      @sibling.destroy!
      @other.destroy!
      first_account = @account
      second_account = CollavreGithub::Account.create!(
        user: users(:two),
        github_uid: "second-reprovisioner",
        login: "second-reprovisioner",
        name: "Second Reprovisioner",
        token: "second-token"
      )
      first = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:tshirt),
        github_account: first_account,
        repository_full_name: "owner/shared",
        repository_id: 222
      )
      second = CollavreGithub::RepositoryLink.create!(
        creative: creatives(:childless_creative),
        github_account: second_account,
        repository_full_name: "owner/shared",
        repository_id: 222
      )
      calls = []
      provision = lambda do |**kwargs|
        calls << kwargs
        status = kwargs[:account] == first_account ? :failed : :updated
        [ [ kwargs[:links].first, status ] ]
      end
      client = IdentityClient.new(hooks: [], repository_id: 222)

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
        end
      end

      assert_equal [ [ "owner/shared", :updated ] ], results
      assert_equal [ first, second ], calls.map { |call| call[:links].first }
      assert_equal [ first_account, second_account ], calls.map { |call| call[:account] }
      assert calls.all? { |call| call[:force_hook_refresh] }
    end

    test "serializes identity repair and hook refresh by repository id" do
      @primary.destroy!
      @sibling.destroy!
      inside_lock = false
      identity_verified_inside_lock = false
      lock_events = []
      test_case = self
      client = Object.new
      client.define_singleton_method(:repository_identity) do |repository_name|
        identity_verified_inside_lock = inside_lock
        RepositoryIdentity.new(202, repository_name)
      end
      lock = lambda do |repository_id, &block|
        test_case.assert_equal 202, repository_id
        lock_events << :entered
        @other.update_column(:markdown_sync_enabled, true)
        inside_lock = true
        block.call
      ensure
        inside_lock = false
        lock_events << :released
      end
      provision = lambda do |links:, force_hook_refresh:, **|
        test_case.assert inside_lock
        test_case.assert_equal [ @other.id ], links.map(&:id)
        test_case.assert links.fetch(0).markdown_sync_enabled?
        test_case.assert force_hook_refresh
        [ [ links.fetch(0), :updated ] ]
      end

      results = CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::RepositoryProvisioningLock.stub(:with_lock, lock) do
          CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
            CollavreGithub::WebhookReprovisioner.call(
              webhook_url: "https://example.com/github/webhooks"
            )
          end
        end
      end

      assert_equal [ [ "owner/other", :updated ] ], results
      assert_equal [ :entered, :released ], lock_events
      assert identity_verified_inside_lock,
        "repository identity must be verified inside the provisioning lock"
    end

    test "skips a candidate removed while waiting for the repository lock" do
      @primary.destroy!
      @sibling.destroy!
      calls = []
      lock = lambda do |_repository_id, &block|
        @other.destroy!
        block.call
      end
      provision = lambda do |**kwargs|
        calls << kwargs
        [ [ kwargs[:links].first, :updated ] ]
      end

      results = CollavreGithub::RepositoryProvisioningLock.stub(:with_lock, lock) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          CollavreGithub::WebhookReprovisioner.call(
            webhook_url: "https://example.com/github/webhooks"
          )
        end
      end

      assert_equal [ [ "owner/other", :skipped_unverified ] ], results
      assert_empty calls
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

      assert_equal [ [ "owner/other", :manual_verification_required ], [ "owner/repo", :updated ] ], results
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

      assert_equal [ [ "owner/other", :manual_verification_required ], [ "owner/repo", :updated ] ], results
      assert_equal [ @primary ], calls.map { |call| call[:links].first }
      assert_nil @other.reload.repository_id
      assert_equal [ "Owner/Repo" ], client.repository_names
    end
  end
end
