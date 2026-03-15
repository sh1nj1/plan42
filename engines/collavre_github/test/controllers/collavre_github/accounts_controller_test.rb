require_relative "../../test_helper"

module CollavreGithub
  class AccountsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = create_user(email: "gh-account@example.com", name: "GH Account User")
      @account = create_github_account(@user)
    end

    test "show returns account info" do
      sign_in_as(@user)

      get "/github/account",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert_equal @account.login, data["login"]
      assert_equal @account.name, data["name"]
    end

    test "show returns error when not connected" do
      @account.destroy!
      sign_in_as(@user)

      get "/github/account",
          headers: { "Accept" => "application/json" }

      assert_response :unprocessable_entity
      data = JSON.parse(response.body)
      assert_equal "not_connected", data["error"]
    end

    test "organizations returns user org plus github orgs" do
      sign_in_as(@user)

      stub_github_organizations([
        { id: 100, login: "acme", name: "ACME Corp", type: "Organization" }
      ])

      get "/github/account/organizations",
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      orgs = data["organizations"]
      # User org + github orgs
      assert orgs.size >= 1
      # First is user's own
      assert_equal @account.login, orgs[0]["login"]
      assert_equal "User", orgs[0]["type"]
      # Check that acme org is present
      acme = orgs.find { |o| o["login"] == "acme" }
      assert_not_nil acme, "Expected 'acme' org in response"
    end

    test "repositories returns repos for user" do
      sign_in_as(@user)

      stub_github_user_repos([
        { id: 1, name: "my-app", full_name: "testuser/my-app" }
      ])

      get "/github/account/repositories",
          params: { organization: @account.login },
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert_equal 1, data["repositories"].size
      assert_equal "testuser/my-app", data["repositories"][0]["full_name"]
    end

    test "repositories returns repos for organization" do
      sign_in_as(@user)

      stub_github_org_repos("acme", [
        { id: 10, name: "backend", full_name: "acme/backend" },
        { id: 11, name: "frontend", full_name: "acme/frontend" }
      ])

      get "/github/account/repositories",
          params: { organization: "acme" },
          headers: { "Accept" => "application/json" }

      assert_response :success
      data = JSON.parse(response.body)
      assert_equal 2, data["repositories"].size
      assert_equal %w[acme/backend acme/frontend], data["repositories"].map { |r| r["full_name"] }
    end
  end
end
