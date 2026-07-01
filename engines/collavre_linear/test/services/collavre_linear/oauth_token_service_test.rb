# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

WebMock.disable_net_connect!

module CollavreLinear
  class OAuthTokenServiceTest < ActiveSupport::TestCase
    LINEAR_TOKEN_ENDPOINT = "https://api.linear.app/oauth/token"

    setup do
      @user = Collavre.user_class.create!(
        email: "linear-oauth-test@example.com",
        name: "Linear OAuth Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )
      ENV["LINEAR_CLIENT_ID"]          ||= "test-client-id"
      ENV["LINEAR_CLIENT_SECRET"]      ||= "test-client-secret"
      ENV["LINEAR_OAUTH_REDIRECT_URI"] ||= "https://example.com/linear/auth/callback"
    end

    # ---------------------------------------------------------------------------
    # authorize_url
    # ---------------------------------------------------------------------------
    test "authorize_url includes actor=app parameter" do
      url = CollavreLinear::OAuthTokenService.authorize_url(state: "abc", creative_id: "42")
      assert_includes url, "actor=app"
    end

    test "authorize_url includes required scopes" do
      url = CollavreLinear::OAuthTokenService.authorize_url(state: "xyz", creative_id: "1")
      assert_includes url, "read"
      assert_includes url, "write"
      assert_includes url, "issues%3Acreate"
      assert_includes url, "comments%3Acreate"
    end

    test "authorize_url includes client_id from env" do
      url = CollavreLinear::OAuthTokenService.authorize_url(state: "s1", creative_id: "5")
      assert_includes url, "client_id=#{ENV.fetch('LINEAR_CLIENT_ID', 'test-client-id')}"
    end

    test "authorize_url includes redirect_uri" do
      url = CollavreLinear::OAuthTokenService.authorize_url(state: "s2", creative_id: "5")
      assert_includes url, "redirect_uri="
      assert_includes url, CGI.escape("https://example.com/linear/auth/callback")
    end

    test "authorize_url includes state parameter" do
      url = CollavreLinear::OAuthTokenService.authorize_url(state: "mystate", creative_id: "5")
      assert_includes url, "state=mystate"
    end

    # ---------------------------------------------------------------------------
    # exchange
    # ---------------------------------------------------------------------------
    test "exchange posts to token endpoint and returns token hash" do
      stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            access_token: "acc-tok-123",
            refresh_token: "ref-tok-456",
            expires_in: 86400,
            token_type: "Bearer"
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = CollavreLinear::OAuthTokenService.exchange("auth-code-abc")

      assert_equal "acc-tok-123", result[:access_token]
      assert_equal "ref-tok-456", result[:refresh_token]
      assert_equal 86400,         result[:expires_in]
      assert_requested :post, LINEAR_TOKEN_ENDPOINT, times: 1
    end

    test "exchange sends correct code and grant_type" do
      stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .to_return(
          status: 200,
          body: { access_token: "a", refresh_token: "r", expires_in: 3600 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      CollavreLinear::OAuthTokenService.exchange("my-code-xyz")

      assert_requested :post, LINEAR_TOKEN_ENDPOINT do |req|
        body = URI.decode_www_form(req.body).to_h
        body["code"] == "my-code-xyz" && body["grant_type"] == "authorization_code"
      end
    end

    test "exchange raises OAuthTokenService::Error on non-200" do
      stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      assert_raises(CollavreLinear::OAuthTokenService::Error) do
        CollavreLinear::OAuthTokenService.exchange("bad-code")
      end
    end

    # ---------------------------------------------------------------------------
    # refresh
    # ---------------------------------------------------------------------------
    test "refresh posts grant_type=refresh_token and persists new token" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "usr-refresh-test",
        access_token: "old-access",
        refresh_token: "my-refresh-token",
        token_expires_at: 2.minutes.from_now
      )

      stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .to_return(
          status: 200,
          body: {
            access_token: "new-access-tok",
            refresh_token: "new-refresh-tok",
            expires_in: 86400
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = CollavreLinear::OAuthTokenService.refresh(account)

      assert_equal account, result
      account.reload
      assert_equal "new-access-tok", account.access_token
      assert_equal "new-refresh-tok", account.refresh_token
      assert account.token_expires_at > 1.hour.from_now, "token_expires_at should be advanced"

      assert_requested :post, LINEAR_TOKEN_ENDPOINT do |req|
        body = URI.decode_www_form(req.body).to_h
        body["grant_type"] == "refresh_token" && body["refresh_token"] == "my-refresh-token"
      end
    end

    test "refresh does not call endpoint if token not expiring soon" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "usr-not-expiring",
        access_token: "still-valid",
        refresh_token: "rr",
        token_expires_at: 2.hours.from_now
      )

      result = CollavreLinear::OAuthTokenService.refresh(account)

      assert_equal account, result
      assert_not_requested :post, LINEAR_TOKEN_ENDPOINT
    end

    test "refresh raises OAuthTokenService::Error on failure" do
      account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "usr-refresh-fail",
        access_token: "expiring",
        refresh_token: "bad-refresh",
        token_expires_at: 1.minute.from_now
      )

      stub_request(:post, LINEAR_TOKEN_ENDPOINT)
        .to_return(status: 401, body: { error: "invalid_token" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      assert_raises(CollavreLinear::OAuthTokenService::Error) do
        CollavreLinear::OAuthTokenService.refresh(account)
      end
    end
  end
end
