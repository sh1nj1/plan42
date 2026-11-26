require "test_helper"

class ApplicationControllerSecurityTest < ActionDispatch::IntegrationTest
  test "should allow request with valid origin secret" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123") do
      get root_path, headers: { "X-Origin-Secret" => "secret123" }, env: { "REMOTE_ADDR" => "1.2.3.4" }
      assert_response :success
    end
  end

  test "should forbid request with invalid origin secret" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123") do
      get root_path, headers: { "X-Origin-Secret" => "wrong_secret" }, env: { "REMOTE_ADDR" => "1.2.3.4" }
      assert_response :forbidden
    end
  end

  test "should forbid request without origin secret" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123") do
      get root_path, env: { "REMOTE_ADDR" => "1.2.3.4" }
      assert_response :forbidden
    end
  end

  test "should allow request without origin secret if env var is not set" do
    with_env("ORIGIN_SHARED_SECRET" => nil) do
      get root_path
      assert_response :success
    end
  end

  test "should allow health check requests without secret" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123") do
      get "/up"
      assert_response :success
    end
  end

  test "should forbid whitelisted path request with invalid secret" do
    begin
      Rails.application.routes.draw do
        get "health_test" => "collavre/creatives#index"
      end

      with_env("ORIGIN_SHARED_SECRET" => "secret123") do
        get "/health_test", headers: { "X-Origin-Secret" => "wrong_secret" }
        assert_response :forbidden
      end
    ensure
      Rails.application.reload_routes!
    end
  end

  test "uses the verified CloudFront viewer address for new sessions" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123", "TRUST_CLOUDFRONT_VIEWER_ADDRESS" => "true") do
      assert_session_ip "198.51.100.10:53124", "198.51.100.10"
      assert_session_ip "[2001:db8::1]:443", "2001:db8::1"
      assert_session_ip "2001:db8::2:443", "2001:db8::2"
    end
  end

  test "falls back to the Rails IP for missing or invalid viewer addresses" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123", "TRUST_CLOUDFRONT_VIEWER_ADDRESS" => "true") do
      assert_session_ip nil, "192.0.2.9"
      assert_session_ip "198.51.100.10:443, 203.0.113.4:443", "192.0.2.9"
      assert_session_ip "198.51.100.10/24:443", "192.0.2.9"
      assert_session_ip "999.51.100.10:443", "192.0.2.9"
      assert_session_ip "198.51.100.10:65536", "192.0.2.9"
    end
  end

  test "ignores a viewer header when the CloudFront policy has not been enabled" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123", "TRUST_CLOUDFRONT_VIEWER_ADDRESS" => "false") do
      assert_session_ip "198.51.100.10:443", "192.0.2.9"
    end
  end

  test "ignores a viewer header when no origin secret is configured" do
    with_env("ORIGIN_SHARED_SECRET" => nil, "TRUST_CLOUDFRONT_VIEWER_ADDRESS" => "true") do
      assert_session_ip "198.51.100.10:443", "192.0.2.9", origin_secret: nil
    end
  end

  test "rejects a viewer header accompanied by an invalid origin secret" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123", "TRUST_CLOUDFRONT_VIEWER_ADDRESS" => "true") do
      assert_no_difference("Collavre::Session.count") do
        post collavre.session_path, params: { email: users(:one).email, password: "password" },
          headers: { "CloudFront-Viewer-Address" => "198.51.100.10:443", "X-Origin-Secret" => "wrong" }
      end
      assert_response :forbidden
    end
  end

  test "signup limit uses the viewer IP and leaves the login counter separate" do
    with_env("ORIGIN_SHARED_SECRET" => "secret123", "TRUST_CLOUDFRONT_VIEWER_ADDRESS" => "true") do
      limit = Rails.configuration.x.sessions_create_rate_limit[:to]
      key = "rate-limit:collavre/users:198.51.100.10"
      Rails.cache.write(key, limit)
      signup_params = { user: { name: "Signup Test", email: "signup-limit@example.com",
                                password: TEST_PASSWORD, password_confirmation: TEST_PASSWORD } }
      headers = { "X-Origin-Secret" => "secret123" }

      assert_no_difference("Collavre::User.count") do
        post collavre.users_path, params: signup_params.merge(invite_token: "test-token"),
          headers: headers.merge("CloudFront-Viewer-Address" => "198.51.100.10:54321"),
          env: { "REMOTE_ADDR" => "192.0.2.9" }
      end
      assert_redirected_to collavre.new_user_path(invite_token: "test-token")
      assert_equal I18n.t("errors.rate_limit_exceeded"), flash[:alert]

      assert_session_ip "198.51.100.10:54322", "198.51.100.10"

      assert_difference("Collavre::User.count", 1) do
        post collavre.users_path, params: signup_params,
          headers: headers.merge("CloudFront-Viewer-Address" => "198.51.100.11:54321"),
          env: { "REMOTE_ADDR" => "192.0.2.9" }
      end
      assert_redirected_to collavre.new_session_path
    ensure
      Rails.cache.delete(key)
    end
  end

  private

  def assert_session_ip(viewer_address, expected_ip, origin_secret: "secret123")
    user = users(:one)
    user.update_column(:email_verified_at, Time.current)
    headers = { "X-Forwarded-For" => "203.0.113.6, 192.0.2.9" }
    headers["X-Origin-Secret"] = origin_secret if origin_secret
    headers["CloudFront-Viewer-Address"] = viewer_address if viewer_address
    assert_difference("Collavre::Session.count", 1) do
      post collavre.session_path, params: { email: user.email, password: "password" },
        headers: headers, env: { "REMOTE_ADDR" => "10.0.0.2" }
    end
    assert_equal expected_ip, user.sessions.order(:id).last.ip_address
  end

  def with_env(env)
    original_env = ENV.to_hash
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    ENV.replace(original_env)
  end
end
