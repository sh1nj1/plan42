require_relative "../../test_helper"

module CollavreGithub
  class IntegrationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = create_user(email: "gh-integration@example.com", name: "GH Integration User")
      @creative = create_creative(@user)
      @account = create_github_account(@user)
    end

    # --- Show (GET) ---

    test "show returns connected status with no repositories" do
      sign_in_as(@user)

      get "/github/creatives/#{@creative.id}/integration",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert data["connected"]
      assert_equal @account.login, data["account"]["login"]
      assert_equal [], data["selected_repositories"]
    end

    test "show returns not connected when user has no github account" do
      @account.destroy!
      sign_in_as(@user)

      get "/github/creatives/#{@creative.id}/integration",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert_not data["connected"]
    end

    test "show returns selected repositories" do
      sign_in_as(@user)

      CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/repo1"
      )

      get "/github/creatives/#{@creative.id}/integration",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert_includes data["selected_repositories"], "testuser/repo1"
    end

    # --- Organizations ---

    test "organizations returns mocked github orgs" do
      sign_in_as(@user)

      stub_github_organizations([
        { id: 1, login: "myorg", name: "My Org", type: "Organization" },
        { id: 2, login: "other", name: "Other Org", type: "Organization" }
      ])

      get "/github/account/organizations",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      orgs = data["organizations"]

      # First one is the user's own account
      assert_equal @account.login, orgs[0]["login"]
      assert_equal "User", orgs[0]["type"]

      # Then the orgs from GitHub
      assert_equal "myorg", orgs[1]["login"]
      assert_equal "other", orgs[2]["login"]
    end

    test "organizations returns only user org when github api fails" do
      sign_in_as(@user)

      # Client rescues errors and returns [], so only user org remains
      stub_request(:get, %r{https://api\.github\.com/user/orgs})
        .to_return(status: 401, body: { message: "Bad credentials" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      get "/github/account/organizations",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      orgs = data["organizations"]
      assert_equal 1, orgs.size
      assert_equal @account.login, orgs[0]["login"]
    end

    # --- Repositories ---

    test "repositories returns user repos" do
      sign_in_as(@user)

      stub_github_user_repos([
        { id: 1, name: "repo1", full_name: "testuser/repo1" },
        { id: 2, name: "repo2", full_name: "testuser/repo2" }
      ])

      get "/github/account/repositories",
          params: { organization: @account.login, creative_id: @creative.id },
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      repos = data["repositories"]
      assert_equal 2, repos.size
      assert_equal "testuser/repo1", repos[0]["full_name"]
    end

    test "repositories marks selected repos" do
      sign_in_as(@user)

      CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/repo1"
      )

      stub_github_user_repos([
        { id: 1, name: "repo1", full_name: "testuser/repo1" },
        { id: 2, name: "repo2", full_name: "testuser/repo2" }
      ])

      get "/github/account/repositories",
          params: { organization: @account.login, creative_id: @creative.id },
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      repos = data["repositories"]
      selected = repos.find { |r| r["full_name"] == "testuser/repo1" }
      unselected = repos.find { |r| r["full_name"] == "testuser/repo2" }
      assert selected["selected"]
      assert_not unselected["selected"]
    end

    test "repositories returns org repos" do
      sign_in_as(@user)

      stub_github_org_repos("myorg", [
        { id: 10, name: "org-repo", full_name: "myorg/org-repo" }
      ])

      get "/github/account/repositories",
          params: { organization: "myorg" },
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert_equal 1, data["repositories"].size
      assert_equal "myorg/org-repo", data["repositories"][0]["full_name"]
    end

    # --- Update (PATCH) ---

    test "update links repositories" do
      sign_in_as(@user)

      stub_github_repository("testuser/repo1", id: 101)
      stub_github_hooks("testuser/repo1")
      stub_github_create_hook("testuser/repo1")
      lock_events = []
      lock = lambda do |repository_id, &block|
        lock_events << [ :entered, repository_id ]
        block.call
        lock_events << [ :released, repository_id ]
      end

      CollavreGithub::RepositoryProvisioningLock.stub(:with_lock, lock) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: { repositories: [ "testuser/repo1" ] },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :success
      data = JSON.parse(response.body)
      assert data["success"]
      assert_includes data["selected_repositories"], "testuser/repo1"
      assert data["webhooks"]["testuser/repo1"].present?
      assert_equal [ [ :entered, 101 ], [ :released, 101 ] ], lock_events
    end

    test "update revalidates repository identity after acquiring the provisioning lock" do
      link = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        webhook_secret: "repository-a-secret"
      )
      sign_in_as(@user)
      identity_stub = stub_request(:get, "https://api.github.com/repos/testuser/old-name")
        .to_return(
          {
            status: 200,
            body: { id: 101, full_name: "testuser/old-name" }.to_json,
            headers: { "Content-Type" => "application/json" }
          },
          {
            status: 200,
            body: { id: 202, full_name: "testuser/old-name" }.to_json,
            headers: { "Content-Type" => "application/json" }
          }
        )
      provisioned = false

      CollavreGithub::WebhookProvisioner.stub(
        :ensure_for_links,
        ->(**) {
          provisioned = true
          []
        }
      ) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: { repositories: [ "testuser/old-name" ] },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :unprocessable_entity
      assert_requested identity_stub, times: 2
      assert_not provisioned
      assert_equal "testuser/old-name", link.reload.repository_full_name
      assert_equal 101, link.repository_id
      assert_equal "repository-a-secret", link.webhook_secret
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/old-name/hooks}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/old-name/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/old-name/hooks/}
    end

    test "update deduplicates aliases that resolve to the same repository" do
      sign_in_as(@user)

      stub_github_repository("TestUser/Repo1", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)
      stub_github_hooks("testuser/repo1")
      stub_github_create_hook("testuser/repo1")

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "TestUser/Repo1", "testuser/repo1" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :success
      links = @creative.effective_origin.github_repository_links.where(github_account: @account)
      assert_equal 1, links.count
      assert_equal 101, links.first.repository_id
      assert_equal "testuser/repo1", links.first.repository_full_name
    end

    test "alias dedup preserves an existing canonical link and its settings" do
      existing = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        webhook_hook_id: 77,
        markdown_sync_enabled: true,
        markdown_root_creative: @creative.effective_origin,
        sync_branch: "docs"
      )
      sign_in_as(@user)

      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)
      provision = lambda do |links:, **|
        assert_equal [ existing.id ], links.map(&:id)
        assert_equal "testuser/repo1", links.first.repository_full_name
        []
      end

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: {
                repositories: [ "testuser/old-name", "testuser/repo1" ],
                markdown_sync: { "testuser/repo1" => false }
              },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :success
      links = @creative.effective_origin.github_repository_links.where(github_account: @account)
      assert_equal [ existing.id ], links.pluck(:id)
      existing.reload
      assert_equal "testuser/repo1", existing.repository_full_name
      assert_equal 77, existing.webhook_hook_id
      assert_not existing.markdown_sync_enabled?
      assert_equal @creative.effective_origin, existing.markdown_root_creative
      assert_equal "docs", existing.sync_branch
    end

    test "failed hook refresh rolls a canonical collision merge back" do
      stale = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        webhook_secret: "active-secret",
        webhook_hook_id: 77,
        markdown_sync_enabled: true
      )
      canonical = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/repo1",
        repository_id: 101,
        webhook_secret: "canonical-secret"
      )
      sign_in_as(@user)

      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)
      provision = lambda do |links:, **|
        assert_equal [ canonical.id ], links.map(&:id)
        assert_equal "active-secret", links.first.webhook_secret
        [ [ links.first, :failed ] ]
      end

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: { repositories: [ "testuser/old-name", "testuser/repo1" ] },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :unprocessable_entity
      assert_equal "testuser/old-name", stale.reload.repository_full_name
      assert_equal "active-secret", stale.webhook_secret
      assert_equal 77, stale.webhook_hook_id
      assert stale.markdown_sync_enabled?
      assert_equal "testuser/repo1", canonical.reload.repository_full_name
      assert_equal "canonical-secret", canonical.webhook_secret
    end

    test "canonical collision keeps the verified account and anchor secret" do
      stale = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        webhook_secret: "active-secret"
      )
      other_user = create_user(email: "gh-other-account@example.com", name: "Other GitHub User")
      other_account = create_github_account(other_user)
      canonical = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: other_account,
        repository_full_name: "testuser/repo1",
        repository_id: 101,
        webhook_secret: "other-secret"
      )
      sign_in_as(@user)

      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)
      provision = lambda do |account:, links:, **|
        assert_equal @account, account
        assert_equal [ canonical.id ], links.map(&:id)
        assert_equal @account, links.first.github_account
        assert_equal "active-secret", links.first.webhook_secret
        [ [ links.first, :updated ] ]
      end

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: { repositories: [ "testuser/old-name" ] },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :success
      assert_not CollavreGithub::RepositoryLink.exists?(stale.id)
      canonical.reload
      assert_equal @account, canonical.github_account
      assert_equal "active-secret", canonical.webhook_secret
      assert_equal "testuser/repo1", canonical.repository_full_name
    end

    test "canonicalization rejects an unverified canonical-name collision" do
      stale = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        webhook_secret: "active-secret"
      )
      collision = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/repo1",
        repository_id: nil,
        webhook_secret: "unverified-secret"
      )
      sign_in_as(@user)

      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "testuser/old-name" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :unprocessable_entity
      assert_equal "testuser/old-name", stale.reload.repository_full_name
      assert_equal 101, stale.repository_id
      assert_equal "testuser/repo1", collision.reload.repository_full_name
      assert_nil collision.repository_id
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/repo1/hooks}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/repo1/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/repo1/hooks/}
    end

    test "a later provisioning failure does not roll back an earlier successful repository" do
      sign_in_as(@user)

      stub_github_repository("testuser/repo1", id: 101)
      stub_github_repository("testuser/repo2", id: 202)
      provisioned = []
      provision = lambda do |links:, **|
        link = links.fetch(0)
        provisioned << link.repository_full_name
        status = link.repository_id == 101 ? :updated : :failed
        [ [ link, status ] ]
      end

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: { repositories: [ "testuser/repo1", "testuser/repo2" ] },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :unprocessable_entity
      assert_equal [ "testuser/repo1", "testuser/repo2" ], provisioned
      links = @creative.effective_origin.github_repository_links.where(github_account: @account)
      assert_equal [ [ "testuser/repo1", 101 ] ],
        links.order(:repository_full_name).pluck(:repository_full_name, :repository_id)
    end

    test "markdown sync is applied before a forced hook refresh" do
      sign_in_as(@user)

      stub_github_repository("testuser/repo1", id: 101)
      provision = lambda do |links:, force_hook_refresh:, **|
        assert links.fetch(0).markdown_sync_enabled?
        assert force_hook_refresh
        [ [ links.fetch(0), :updated ] ]
      end
      enqueued_link_ids = []

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        CollavreGithub::InitialMarkdownSyncJob.stub(
          :perform_later,
          ->(link_id) { enqueued_link_ids << link_id }
        ) do
          patch "/github/creatives/#{@creative.id}/integration",
                params: {
                  repositories: [ "testuser/repo1" ],
                  markdown_sync: { "testuser/repo1" => true }
                },
                headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
                as: :json
        end
      end

      assert_response :success
      link = @creative.effective_origin.github_repository_links.find_by!(github_account: @account)
      assert link.markdown_sync_enabled?
      assert_equal [ link.id ], enqueued_link_ids
    end

    test "canonicalization preserves a markdown disable keyed by the submitted alias" do
      link = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        markdown_sync_enabled: true
      )
      sign_in_as(@user)
      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)

      provision = lambda do |links:, **|
        assert_not links.fetch(0).markdown_sync_enabled?
        [ [ links.fetch(0), :updated ] ]
      end

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: {
                repositories: [ "testuser/old-name" ],
                markdown_sync: { "testuser/old-name" => false }
              },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :success
      assert_equal "testuser/repo1", link.reload.repository_full_name
      assert_not link.markdown_sync_enabled?
    end

    test "canonicalization preserves a markdown enable keyed by the submitted alias" do
      link = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-name",
        repository_id: 101,
        markdown_sync_enabled: false
      )
      sign_in_as(@user)
      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)
      enqueued_link_ids = []

      provision = lambda do |links:, **|
        assert links.fetch(0).markdown_sync_enabled?
        [ [ links.fetch(0), :updated ] ]
      end

      CollavreGithub::WebhookProvisioner.stub(:ensure_for_links, provision) do
        CollavreGithub::InitialMarkdownSyncJob.stub(
          :perform_later,
          ->(link_id) { enqueued_link_ids << link_id }
        ) do
          patch "/github/creatives/#{@creative.id}/integration",
                params: {
                  repositories: [ "testuser/old-name" ],
                  markdown_sync: { "testuser/old-name" => true }
                },
                headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
                as: :json
        end
      end

      assert_response :success
      assert_equal "testuser/repo1", link.reload.repository_full_name
      assert link.markdown_sync_enabled?
      assert_equal [ link.id ], enqueued_link_ids
    end

    test "canonicalization rejects conflicting markdown toggles for repository aliases" do
      sign_in_as(@user)
      stub_github_repository("testuser/old-name", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)

      patch "/github/creatives/#{@creative.id}/integration",
            params: {
              repositories: [ "testuser/old-name", "testuser/repo1" ],
              markdown_sync: {
                "testuser/old-name" => true,
                "testuser/repo1" => false
              }
            },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :unprocessable_entity
      assert_empty @creative.effective_origin.github_repository_links
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/repo1/hooks}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/repo1/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/repo1/hooks/}
    end

    test "canonicalization rejects conflicting toggles for case-only aliases" do
      sign_in_as(@user)
      stub_github_repository("TestUser/Repo1", id: 101, full_name: "testuser/repo1")
      stub_github_repository("testuser/repo1", id: 101)

      patch "/github/creatives/#{@creative.id}/integration",
            params: {
              repositories: [ "TestUser/Repo1", "testuser/repo1" ],
              markdown_sync: {
                "TestUser/Repo1" => true,
                "testuser/repo1" => false
              }
            },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :unprocessable_entity
      assert_empty @creative.effective_origin.github_repository_links
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/repo1/hooks}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/repo1/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/repo1/hooks/}
    end

    test "update replaces existing repositories" do
      sign_in_as(@user)

      CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-repo"
      )

      stub_github_repository("testuser/new-repo", id: 202)
      stub_github_hooks("testuser/new-repo")
      stub_github_create_hook("testuser/new-repo")

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "testuser/new-repo" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :success
      data = JSON.parse(response.body)
      assert_includes data["selected_repositories"], "testuser/new-repo"
      assert_not_includes data["selected_repositories"], "testuser/old-repo"
    end

    test "new links persist identity before sharing an existing repository hook" do
      existing = CollavreGithub::RepositoryLink.create!(
        creative: create_creative(@user),
        github_account: @account,
        repository_full_name: "testuser/repo1",
        repository_id: 101,
        webhook_secret: "existing-secret"
      )
      sign_in_as(@user)

      stub_github_repository("testuser/repo1", id: 101)
      stub_github_hooks("testuser/repo1")
      stub_github_create_hook("testuser/repo1")

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "testuser/repo1" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :success
      linked = @creative.effective_origin.github_repository_links.find_by!(
        github_account: @account,
        repository_full_name: "testuser/repo1"
      )
      assert_equal 101, linked.repository_id
      assert_equal existing.webhook_secret, linked.webhook_secret
    end

    test "re-saving a name-only legacy link does not provision the reused name" do
      legacy = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/reused",
        repository_id: nil,
        webhook_secret: "legacy-secret"
      )
      sign_in_as(@user)

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "testuser/reused" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :success
      assert_nil legacy.reload.repository_id
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/reused}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/reused/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/reused/hooks/}
    end

    test "a name-only legacy link cannot enable markdown import" do
      legacy = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/reused",
        repository_id: nil,
        webhook_secret: "legacy-secret"
      )
      sign_in_as(@user)
      sync_enqueued = false

      CollavreGithub::InitialMarkdownSyncJob.stub(:perform_later, ->(*) { sync_enqueued = true }) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: {
                repositories: [ "testuser/reused" ],
                markdown_sync: { "testuser/reused" => true }
              },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :unprocessable_entity
      assert_not sync_enqueued
      assert_not legacy.reload.markdown_sync_enabled?
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/reused}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/reused/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/reused/hooks/}
    end

    test "re-saving a stale id-backed link rejects all downstream mutations" do
      stale = CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/reused",
        repository_id: 111,
        webhook_secret: "stale-secret"
      )
      sign_in_as(@user)
      stub_github_repository("testuser/reused", id: 222)

      sync_enqueued = false
      CollavreGithub::InitialMarkdownSyncJob.stub(:perform_later, ->(*) { sync_enqueued = true }) do
        patch "/github/creatives/#{@creative.id}/integration",
              params: {
                repositories: [ "testuser/reused" ],
                markdown_sync: { "testuser/reused" => true }
              },
              headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
              as: :json
      end

      assert_response :unprocessable_entity
      assert_not sync_enqueued
      assert_equal 111, stale.reload.repository_id
      assert_not stale.markdown_sync_enabled?
      assert_not_requested :get, %r{https://api\.github\.com/repos/testuser/reused/hooks}
      assert_not_requested :post, %r{https://api\.github\.com/repos/testuser/reused/hooks}
      assert_not_requested :patch, %r{https://api\.github\.com/repos/testuser/reused/hooks/}
    end

    test "update returns error when not connected" do
      @account.destroy!
      sign_in_as(@user)

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "testuser/repo1" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :unprocessable_entity
    end

    # --- Destroy (DELETE) ---

    test "destroy removes selected repositories" do
      sign_in_as(@user)

      CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/repo1"
      )
      CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/repo2"
      )

      # Stub webhook removal
      stub_github_hooks("testuser/repo1")

      delete "/github/creatives/#{@creative.id}/integration",
             params: { repositories: [ "testuser/repo1" ] },
             headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
             as: :json

      assert_response :success
      data = JSON.parse(response.body)
      assert data["success"]
      assert_not_includes data["selected_repositories"], "testuser/repo1"
      assert_includes data["selected_repositories"], "testuser/repo2"
    end

    test "destroy returns not found for non-linked repo" do
      sign_in_as(@user)

      delete "/github/creatives/#{@creative.id}/integration",
             params: { repositories: [ "testuser/nonexistent" ] },
             headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
             as: :json

      assert_response :not_found
    end
  end
end
