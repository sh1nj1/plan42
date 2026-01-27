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

  private

  def with_env(env)
    original_env = ENV.to_hash
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    ENV.replace(original_env)
  end
end
