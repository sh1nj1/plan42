# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

WebMock.disable_net_connect!

module CollavreLinear
  class AuthControllerTest < ActionDispatch::IntegrationTest
    LINEAR_TOKEN_ENDPOINT   = "https://api.linear.app/oauth/token"
    LINEAR_GRAPHQL_ENDPOINT = "https://api.linear.app/graphql"

    setup do
      @user     = Collavre.user_class.create!(
        email: "linear-auth-ctrl@example.com",
        name: "Linear Auth Ctrl",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      @creative = Collavre::Creative.create!(
        description: "Linear auth test creative",
        progress: 0.0,
        user: @user
      )

      ENV["LINEAR_CLIENT_ID"]          ||= "test-client-id"
      ENV["LINEAR_CLIENT_SECRET"]      ||= "test-client-secret"
      ENV["LINEAR_OAUTH_REDIRECT_URI"] ||= "https://example.com/linear/auth/callback"
    end

    # -------------------------------------------------------------------------
    # GET /linear/auth/setup
    # -------------------------------------------------------------------------
    test "setup renders bad_request without creative_id" do
      sign_in_as(@user)
      get "/linear/auth/setup"
      assert_response :bad_request
    end

    test "setup renders not_found for unknown creative_id" do
      sign_in_as(@user)
      get "/linear/auth/setup", params: { creative_id: 999999 }
      assert_response :not_found
    end

    test "setup renders forbidden for user without admin permission" do
      other = Collavre.user_class.create!(
        email: "linear-other-ctrl@example.com",
        name: "Other",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      sign_in_as(other)
      get "/linear/auth/setup", params: { creative_id: @creative.id }
      assert_response :forbidden
    end

    test "setup renders ok for authorized user" do
      sign_in_as(@user)
      get "/linear/auth/setup", params: { creative_id: @creative.id }
      assert_response :ok
    end

    # -------------------------------------------------------------------------
    # GET /linear/auth/callback
    # -------------------------------------------------------------------------
    test "callback creates account with app_actor_id" do
      sign_in_as(@user)

      stub_token_exchange
      stub_viewer_query

      get "/linear/auth/callback", params: { code: "auth-code-001", state: "any-state" }

      assert_response :redirect
      account = CollavreLinear::Account.find_by(user: @user)
      assert_not_nil account
      assert_equal "actor-abc",  account.app_actor_id
      assert_equal "user-uid-1", account.linear_uid
      assert_equal "new-at",     account.access_token
    end

    test "callback updates existing account" do
      sign_in_as(@user)

      CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "user-uid-1",
        access_token: "old-token"
      )

      stub_token_exchange
      stub_viewer_query

      get "/linear/auth/callback", params: { code: "auth-code-002", state: "s" }

      assert_response :redirect
      assert_equal 1, CollavreLinear::Account.where(user: @user).count
      account = CollavreLinear::Account.find_by(user: @user)
      assert_equal "new-at", account.access_token
      assert_equal "actor-abc", account.app_actor_id
    end

    test "callback redirects to setup when creative_id is in session" do
      sign_in_as(@user)

      # Simulate session storing creative_id before OAuth redirect
      post "/linear/auth/store_creative",
           params: { creative_id: @creative.id },
           as: :json
      assert_response :ok

      stub_token_exchange
      stub_viewer_query

      get "/linear/auth/callback", params: { code: "auth-code-003", state: "s" }

      assert_response :redirect
      assert_match(/setup/, response.location)
      assert_match(/creative_id=#{@creative.id}/, response.location)
    end

    test "callback redirects to creatives_path when no session creative_id" do
      sign_in_as(@user)

      stub_token_exchange
      stub_viewer_query

      get "/linear/auth/callback", params: { code: "auth-code-004", state: "s" }

      assert_response :redirect
      assert_match(/creatives/, response.location)
    end

    test "callback requires authentication" do
      get "/linear/auth/callback", params: { code: "c", state: "s" }
      assert_response :redirect
    end

    # -------------------------------------------------------------------------
    # POST /linear/auth/store_creative
    # -------------------------------------------------------------------------
    test "store_creative sets session key" do
      sign_in_as(@user)
      post "/linear/auth/store_creative",
           params: { creative_id: @creative.id },
           as: :json
      assert_response :ok
    end

    test "store_creative requires authentication" do
      post "/linear/auth/store_creative",
           params: { creative_id: @creative.id },
           as: :json
      assert_response :redirect
    end

    private

    def stub_token_exchange
      stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            access_token: "new-at",
            refresh_token: "new-rt",
            expires_in: 7200
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    def stub_viewer_query
      stub_request(:post, LINEAR_GRAPHQL_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            data: {
              viewer: {
                id: "user-uid-1",
                organization: { id: "org-xyz" }
              },
              applicationWithAuthorization: {
                appActor: { id: "actor-abc" }
              }
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
  end
end
