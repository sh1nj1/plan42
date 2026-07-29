require "test_helper"

class ReprovisionGithubWebhooksScriptTest < ActiveSupport::TestCase
  RepositoryIdentity = Struct.new(:id, :full_name)

  test "fails with remediation when legacy links need identity verification" do
    account = CollavreGithub::Account.create!(
      user: users(:one),
      github_uid: "legacy-script",
      login: "legacy-script",
      name: "Legacy Script",
      token: "test-token"
    )
    link = CollavreGithub::RepositoryLink.create!(
      creative: creatives(:tshirt),
      github_account: account,
      repository_full_name: "owner/legacy",
      repository_id: nil
    )
    results = [
      [ "owner/legacy", :failed ]
    ]

    _stdout, stderr = capture_io do
      CollavreGithub::WebhookReprovisioner.stub(:call, results) do
        error = assert_raises(SystemExit) do
          load Rails.root.join("script/reprovision_github_webhooks")
        end
        assert_equal 1, error.status
      end
    end

    assert_includes stderr, "GitHub repository identity verification required for: owner/legacy"
    assert_includes stderr, "GitHub webhook reprovisioning failed for: owner/legacy"
    assert_includes stderr, "link_id=#{link.id} creative_id=#{link.creative_id}"
    assert_includes stderr, "account_id=#{account.id} account=\"legacy-script\""
    assert_includes stderr, "script/verify_github_repository_link_identity"
  end

  test "explicitly verifies and reattaches a legacy link without replacing it" do
    account = CollavreGithub::Account.create!(
      user: users(:one),
      github_uid: "reattach-script",
      login: "reattach-script",
      name: "Reattach Script",
      token: "test-token"
    )
    link = CollavreGithub::RepositoryLink.create!(
      creative: creatives(:tshirt),
      github_account: account,
      repository_full_name: "owner/stale",
      repository_id: nil,
      markdown_sync_enabled: true,
      sync_branch: "docs"
    )
    locked = false
    lock_ids = []
    identity_lookups_inside_lock = []
    lock = lambda do |repository_id, &block|
      lock_ids << repository_id
      account.update!(token: "rotated-token")
      locked = true
      block.call
    ensure
      locked = false
    end
    client = Object.new
    client.define_singleton_method(:repository_identity) do |_repository_name|
      identity_lookups_inside_lock << locked
      RepositoryIdentity.new(4242, "owner/canonical")
    end
    client_tokens = []
    client_factory = lambda do |client_account|
      client_tokens << client_account.token
      client
    end
    provision = lambda do |account:, links:, webhook_url:, force_hook_refresh:|
      assert locked
      assert_equal link.github_account, account
      assert_equal "rotated-token", account.token
      assert_equal [ link.id ], links.map(&:id)
      assert_equal 4242, links.first.repository_id
      assert force_hook_refresh
      assert webhook_url.present?
      [ [ links.first, :updated ] ]
    end

    previous_link_id = ENV["GITHUB_REPOSITORY_LINK_ID"]
    previous_repository = ENV["GITHUB_REPOSITORY"]
    ENV["GITHUB_REPOSITORY_LINK_ID"] = link.id.to_s
    ENV["GITHUB_REPOSITORY"] = "owner/selected"
    stdout, _stderr = capture_io do
      CollavreGithub::RepositoryProvisioningLock.stub(:with_lock, lock) do
        CollavreGithub::Client.stub(:new, client_factory) do
          CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
            load Rails.root.join("script/verify_github_repository_link_identity")
          end
        end
      end
    end

    assert_equal [ 4242 ], lock_ids
    assert_equal [ false, true ], identity_lookups_inside_lock
    assert_equal [ "test-token", "rotated-token" ], client_tokens
    link.reload
    assert_equal 4242, link.repository_id
    assert_equal "owner/canonical", link.repository_full_name
    assert link.markdown_sync_enabled?
    assert_equal "docs", link.sync_branch
    assert_includes stdout, "repository_id=4242"
  ensure
    ENV["GITHUB_REPOSITORY_LINK_ID"] = previous_link_id
    ENV["GITHUB_REPOSITORY"] = previous_repository
  end

  test "failed hook refresh rolls explicit identity changes back" do
    account = CollavreGithub::Account.create!(
      user: users(:one),
      github_uid: "reattach-rollback",
      login: "reattach-rollback",
      name: "Reattach Rollback",
      token: "test-token"
    )
    link = CollavreGithub::RepositoryLink.create!(
      creative: creatives(:tshirt),
      github_account: account,
      repository_full_name: "owner/stale",
      repository_id: nil,
      markdown_sync_enabled: true,
      sync_branch: "docs"
    )
    client = Object.new
    client.define_singleton_method(:repository_identity) do |_repository_name|
      RepositoryIdentity.new(4242, "owner/canonical")
    end
    provision = ->(**) { [ [ link, :failed ] ] }

    previous_link_id = ENV["GITHUB_REPOSITORY_LINK_ID"]
    previous_repository = ENV["GITHUB_REPOSITORY"]
    ENV["GITHUB_REPOSITORY_LINK_ID"] = link.id.to_s
    ENV["GITHUB_REPOSITORY"] = "owner/selected"
    _stdout, stderr = capture_io do
      CollavreGithub::Client.stub(:new, client) do
        CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
          error = assert_raises(SystemExit) do
            load Rails.root.join("script/verify_github_repository_link_identity")
          end
          assert_equal 1, error.status
        end
      end
    end

    link.reload
    assert_nil link.repository_id
    assert_equal "owner/stale", link.repository_full_name
    assert link.markdown_sync_enabled?
    assert_equal "docs", link.sync_branch
    assert_includes stderr, "GitHub webhook provisioning failed for owner/canonical"
  ensure
    ENV["GITHUB_REPOSITORY_LINK_ID"] = previous_link_id
    ENV["GITHUB_REPOSITORY"] = previous_repository
  end

  test "reattach provisions through the explicitly verified account after a survivor merge" do
    verified_account = CollavreGithub::Account.create!(
      user: users(:one),
      github_uid: "reattach-verified",
      login: "reattach-verified",
      name: "Reattach Verified",
      token: "verified-token"
    )
    survivor_account = CollavreGithub::Account.create!(
      user: users(:two),
      github_uid: "reattach-survivor",
      login: "reattach-survivor",
      name: "Reattach Survivor",
      token: "survivor-token"
    )
    link = CollavreGithub::RepositoryLink.create!(
      creative: creatives(:tshirt),
      github_account: verified_account,
      repository_full_name: "owner/stale",
      repository_id: nil,
      webhook_secret: "verified-secret",
      markdown_sync_enabled: true
    )
    survivor = CollavreGithub::RepositoryLink.create!(
      creative: link.creative,
      github_account: survivor_account,
      repository_full_name: "owner/canonical",
      repository_id: 4242,
      webhook_secret: "survivor-secret"
    )
    client = Object.new
    client.define_singleton_method(:repository_identity) do |_repository_name|
      RepositoryIdentity.new(4242, "owner/canonical")
    end
    provision = lambda do |account:, links:, **|
      assert_equal verified_account, account
      assert_equal [ survivor.id ], links.map(&:id)
      [ [ links.first, :updated ] ]
    end

    previous_link_id = ENV["GITHUB_REPOSITORY_LINK_ID"]
    previous_repository = ENV["GITHUB_REPOSITORY"]
    ENV["GITHUB_REPOSITORY_LINK_ID"] = link.id.to_s
    ENV["GITHUB_REPOSITORY"] = "owner/selected"
    CollavreGithub::Client.stub(:new, client) do
      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        capture_io { load Rails.root.join("script/verify_github_repository_link_identity") }
      end
    end

    assert_not CollavreGithub::RepositoryLink.exists?(link.id)
    survivor.reload
    assert_equal verified_account, survivor.github_account
    assert_equal "verified-secret", survivor.webhook_secret
    assert survivor.markdown_sync_enabled?

    results = CollavreGithub::Client.stub(:new, client) do
      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        CollavreGithub::WebhookReprovisioner.call(webhook_url: "https://example.com/github/webhooks")
      end
    end
    assert_equal [ [ "owner/canonical", :updated ] ], results
  ensure
    ENV["GITHUB_REPOSITORY_LINK_ID"] = previous_link_id
    ENV["GITHUB_REPOSITORY"] = previous_repository
  end
end
