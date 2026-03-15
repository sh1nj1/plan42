require_relative "../../test_helper"

module CollavreGithub
  class AuthControllerTest < ActionDispatch::IntegrationTest
    setup do
      @user = create_user(email: "github-auth@example.com", name: "GitHub Auth User")
      @creative = create_creative(@user)
    end

    test "store_creative sets creative_id in session" do
      sign_in_as(@user)

      post "/github/auth/store_creative",
           params: { creative_id: @creative.id },
           headers: { "Content-Type" => "application/json" },
           as: :json

      assert_response :ok
    end

    test "store_creative requires authentication" do
      post "/github/auth/store_creative",
           params: { creative_id: @creative.id },
           headers: { "Content-Type" => "application/json" },
           as: :json

      assert_response :redirect
    end

    test "setup renders wizard with valid creative_id" do
      sign_in_as(@user)

      get "/github/auth/setup", params: { creative_id: @creative.id }

      assert_response :ok
      assert_includes response.body, "wizard"
      assert_includes response.body, @creative.id.to_s
    end

    test "setup returns bad_request without creative_id" do
      sign_in_as(@user)

      get "/github/auth/setup"

      assert_response :bad_request
    end

    test "setup returns not_found for invalid creative_id" do
      sign_in_as(@user)

      get "/github/auth/setup", params: { creative_id: 999999 }

      assert_response :not_found
    end

    test "callback redirects to setup when creative_id in session" do
      sign_in_as(@user)

      # Store creative_id in session
      post "/github/auth/store_creative",
           params: { creative_id: @creative.id },
           headers: { "Content-Type" => "application/json" },
           as: :json
      assert_response :ok

      # Simulate OmniAuth callback
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
        provider: "github",
        uid: "12345",
        info: {
          nickname: "testuser",
          name: "Test User",
          image: "https://avatars.githubusercontent.com/u/12345"
        },
        credentials: {
          token: "ghp-mock-token-abc"
        }
      )

      # Trigger callback
      get "/auth/github/callback"

      assert_response :redirect
      assert_match(/setup/, response.location)
      assert_match(/creative_id=#{@creative.id}/, response.location)

      # Verify account was created
      account = CollavreGithub::Account.find_by(github_uid: "12345")
      assert_not_nil account
      assert_equal "testuser", account.login
      assert_equal "ghp-mock-token-abc", account.token
      assert_equal @user.id, account.user_id
    ensure
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:github] = nil
    end

    test "callback redirects to creatives_path when no creative_id in session" do
      sign_in_as(@user)

      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
        provider: "github",
        uid: "12346",
        info: {
          nickname: "testuser2",
          name: "Test User 2",
          image: "https://avatars.githubusercontent.com/u/12346"
        },
        credentials: {
          token: "ghp-mock-token-def"
        }
      )

      get "/auth/github/callback"

      assert_response :redirect
      assert_match(/creatives/, response.location)
    ensure
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:github] = nil
    end

    test "callback updates existing account token" do
      sign_in_as(@user)

      existing = CollavreGithub::Account.create!(
        user: @user,
        github_uid: "12347",
        login: "oldlogin",
        name: "Old Name",
        token: "ghp-old-token",
        avatar_url: "https://old.avatar"
      )

      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
        provider: "github",
        uid: "12347",
        info: {
          nickname: "newlogin",
          name: "New Name",
          image: "https://new.avatar"
        },
        credentials: {
          token: "ghp-new-token"
        }
      )

      get "/auth/github/callback"

      existing.reload
      assert_equal "newlogin", existing.login
      assert_equal "New Name", existing.name
      assert_equal "ghp-new-token", existing.token
      assert_equal "https://new.avatar", existing.avatar_url
    ensure
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:github] = nil
    end
  end
end
