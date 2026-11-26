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

  test "signup rate limit uses the Rails client IP and a separate login counter" do
    client_ip = "198.51.100.10"
    key = "rate-limit:collavre/users:#{client_ip}"
    Rails.cache.write(key, Rails.configuration.x.sessions_create_rate_limit[:to])
    proxy_env = { "REMOTE_ADDR" => "10.0.0.2" }
    headers = { "X-Forwarded-For" => client_ip }
    signup_params = { user: { name: "Signup Test", email: "signup-limit@example.com",
                              password: TEST_PASSWORD, password_confirmation: TEST_PASSWORD } }

    assert_no_difference("Collavre::User.count") do
      post collavre.users_path, params: signup_params.merge(invite_token: "test-token"),
        headers: headers, env: proxy_env
    end
    assert_redirected_to collavre.new_user_path(invite_token: "test-token")
    assert_equal I18n.t("errors.rate_limit_exceeded"), flash[:alert]

    assert_difference("Collavre::User.count", 1) do
      post collavre.users_path, params: signup_params,
        headers: { "X-Forwarded-For" => "198.51.100.11" }, env: proxy_env
    end
    assert_redirected_to collavre.new_session_path

    user = users(:one)
    user.update!(email_verified_at: Time.current)
    assert_difference("Collavre::Session.count", 1) do
      post collavre.session_path, params: { email: user.email, password: "password" },
        headers: headers, env: proxy_env
    end
    assert_equal client_ip, user.sessions.order(:id).last.ip_address
  ensure
    Rails.cache.delete(key)
  end

  private

  def with_env(env)
    original_env = ENV.to_hash
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    ENV.replace(original_env)
  end
end
