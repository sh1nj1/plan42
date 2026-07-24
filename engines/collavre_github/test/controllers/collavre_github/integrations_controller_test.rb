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

      stub_github_hooks("testuser/repo1")
      stub_github_create_hook("testuser/repo1")

      patch "/github/creatives/#{@creative.id}/integration",
            params: { repositories: [ "testuser/repo1" ] },
            headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
            as: :json

      assert_response :success
      data = JSON.parse(response.body)
      assert data["success"]
      assert_includes data["selected_repositories"], "testuser/repo1"
      assert data["webhooks"]["testuser/repo1"].present?
    end

    test "update replaces existing repositories" do
      sign_in_as(@user)

      CollavreGithub::RepositoryLink.create!(
        creative: @creative.effective_origin,
        github_account: @account,
        repository_full_name: "testuser/old-repo"
      )

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
