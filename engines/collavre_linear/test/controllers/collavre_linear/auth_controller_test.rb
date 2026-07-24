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

    # Helper: drive through store_creative so session state is set, return state value.
    def initiate_oauth(creative_id: nil)
      params = creative_id ? { creative_id: creative_id } : { creative_id: "" }
      post "/linear/auth/store_creative", params: params
      assert_response :see_other
      URI.decode_www_form(URI.parse(response.location).query).to_h["state"]
    end

    test "callback creates account from viewer identity" do
      sign_in_as(@user)

      stub_token_exchange
      stub_viewer_query

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-001", state: state }

      assert_response :redirect
      account = CollavreLinear::Account.find_by(user: @user)
      assert_not_nil account
      # Linear exposes no query for the app actor id; it stays nil (EchoGuard no-ops).
      assert_nil account.app_actor_id
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

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-002", state: state }

      assert_response :redirect
      assert_equal 1, CollavreLinear::Account.where(user: @user).count
      account = CollavreLinear::Account.find_by(user: @user)
      assert_equal "new-at", account.access_token
      assert_nil account.app_actor_id
    end

    test "callback does not reassign a Linear account already owned by another user" do
      # @user already owns the linear identity the viewer query returns.
      CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "user-uid-1",
        access_token: "owner-token"
      )

      other = Collavre.user_class.create!(
        email: "linear-thief@example.com",
        name: "Thief",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      sign_in_as(other)

      stub_token_exchange
      stub_viewer_query # returns user-uid-1

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-steal", state: state }

      assert_response :redirect
      account = CollavreLinear::Account.find_by(linear_uid: "user-uid-1")
      assert_equal @user.id, account.user_id, "account must not be stolen"
      assert_equal "owner-token", account.access_token, "tokens must not be overwritten"
      assert_nil CollavreLinear::Account.find_by(user: other),
        "the second user must not acquire the account"
    end

    test "callback refuses a reconnect into a different workspace when links exist" do
      sign_in_as(@user)

      # Existing account in the OLD workspace, with a project link created there.
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "user-uid-1",
        access_token: "old-token",
        workspace_id: "org-OLD"
      )
      CollavreLinear::ProjectLink.create!(
        account: account,
        creative: @creative,
        linear_project_id: "proj-old",
        team_id: "team-old"
      )

      stub_token_exchange
      stub_viewer_query # returns organization org-xyz (a DIFFERENT workspace)

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-ws", state: state }

      assert_response :redirect
      account.reload
      assert_equal "old-token", account.access_token,
        "token must not be overwritten when the workspace changed under existing links"
      assert_equal "org-OLD", account.workspace_id, "workspace must not be switched under existing links"
    end

    test "callback allows a same-workspace reconnect (token refresh) with links" do
      sign_in_as(@user)

      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "user-uid-1",
        access_token: "old-token",
        workspace_id: "org-xyz" # SAME workspace the viewer query returns
      )
      CollavreLinear::ProjectLink.create!(
        account: account,
        creative: @creative,
        linear_project_id: "proj-1",
        team_id: "team-1"
      )

      stub_token_exchange
      stub_viewer_query # returns organization org-xyz

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-refresh", state: state }

      assert_response :redirect
      account.reload
      assert_equal "new-at", account.access_token, "a same-workspace reconnect must refresh the token"
    end

    test "callback refuses a reconnect when the old workspace is unknown and links exist" do
      sign_in_as(@user)

      # Linked account whose stored workspace is blank (unprovable origin). We
      # cannot prove the reconnect stays in the same workspace, so it must fail
      # safe rather than silently orphan the links against the new token.
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "user-uid-1",
        access_token: "old-token",
        workspace_id: nil
      )
      CollavreLinear::ProjectLink.create!(
        account: account,
        creative: @creative,
        linear_project_id: "proj-blank",
        team_id: "team-blank"
      )

      stub_token_exchange
      stub_viewer_query # returns organization org-xyz

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-unknown-ws", state: state }

      assert_response :redirect
      account.reload
      assert_equal "old-token", account.access_token,
        "token must not be overwritten when the old workspace is unknown and links exist"
      assert_nil account.workspace_id,
        "workspace must not be backfilled from an unprovable reconnect under existing links"
    end

    test "callback redirects to setup when creative_id is in session" do
      sign_in_as(@user)

      stub_token_exchange
      stub_viewer_query

      state = initiate_oauth(creative_id: @creative.id)
      get "/linear/auth/callback", params: { code: "auth-code-003", state: state }

      assert_response :redirect
      # The redirect MUST target the MOUNTED path (/linear/auth/setup), not the
      # engine-internal /auth/setup — otherwise the popup 404s right after a
      # successful Linear authorization.
      assert_match(%r{/linear/auth/setup}, URI.parse(response.location).path)
      assert_match(/creative_id=#{@creative.id}/, response.location)
    end

    test "callback redirects to creatives_path when no session creative_id" do
      sign_in_as(@user)

      stub_token_exchange
      stub_viewer_query

      state = initiate_oauth
      get "/linear/auth/callback", params: { code: "auth-code-004", state: state }

      assert_response :redirect
      assert_match(/creatives/, response.location)
    end

    test "callback requires authentication" do
      get "/linear/auth/callback", params: { code: "c", state: "s" }
      assert_response :redirect
    end

    test "callback rejects missing state parameter" do
      sign_in_as(@user)
      stub_token_exchange
      stub_viewer_query

      initiate_oauth  # sets session state but we won't pass state param
      get "/linear/auth/callback", params: { code: "auth-code-csrf" }

      assert_response :redirect
      assert_nil CollavreLinear::Account.find_by(user: @user)
      assert_not_requested :post, LINEAR_TOKEN_ENDPOINT
    end

    test "callback rejects mismatched state parameter" do
      sign_in_as(@user)
      stub_token_exchange
      stub_viewer_query

      initiate_oauth  # sets session state
      get "/linear/auth/callback", params: { code: "auth-code-csrf2", state: "wrong-state" }

      assert_response :redirect
      assert_nil CollavreLinear::Account.find_by(user: @user)
      assert_not_requested :post, LINEAR_TOKEN_ENDPOINT
    end

    # -------------------------------------------------------------------------
    # POST /linear/auth/store_creative
    # -------------------------------------------------------------------------
    test "store_creative sets session key and redirects to authorize url" do
      sign_in_as(@user)
      post "/linear/auth/store_creative",
           params: { creative_id: @creative.id }
      assert_response :see_other
      assert_includes response.location, "linear.app/oauth/authorize"
      assert_includes response.location, "state="
    end

    test "store_creative requires authentication" do
      post "/linear/auth/store_creative",
           params: { creative_id: @creative.id },
           as: :json
      assert_response :redirect
    end

    test "store_creative fails loudly when OAuth config is missing" do
      # A blank redirect_uri would otherwise build `...&redirect_uri&scope=...`,
      # which Linear can never redirect back from ("already installed" dead-end).
      sign_in_as(@user)
      OAuthTokenService.stub(:missing_config, [ :LINEAR_OAUTH_REDIRECT_URI ]) do
        post "/linear/auth/store_creative", params: { creative_id: @creative.id }
      end
      assert_response :service_unavailable
      assert_includes response.body, "LINEAR_OAUTH_REDIRECT_URI"
      assert_nil session[:linear_creative_id]
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
              }
            }
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end
  end
end
