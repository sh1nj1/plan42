require "test_helper"

class HostRoutesTest < ActionDispatch::IntegrationTest
  # Smoke tests to confirm host-only endpoints still resolve after engine extraction
  # These routes are defined in the main app, not the Collavre engine

  test "health check endpoint resolves" do
    get "/up"
    assert_response :success
  end

  test "PWA manifest route exists" do
    # Route resolves - template missing in test is acceptable
    assert_routing "/manifest", controller: "rails/pwa", action: "manifest"
  end

  test "service worker route exists" do
    # Route resolves - template missing in test is acceptable
    assert_routing "/service-worker", controller: "rails/pwa", action: "service_worker"
  end

  test "admin settings endpoint requires authentication" do
    get "/admin"
    assert_response :redirect # Redirects to login
  end

  test "webauthn registration endpoint resolves" do
    get "/webauthn/registration/new"
    assert_response :redirect # Redirects to login
  end

  test "webauthn session endpoint resolves" do
    get "/webauthn/session/new"
    assert_response :success
  end

  test "github webhook endpoint resolves" do
    post "/github/webhook", params: {}, as: :json
    # GitHub webhook requires valid payload, returns bad request without one
    assert_response :bad_request
  end

  test "oauth protected resource discovery endpoint resolves" do
    get "/.well-known/oauth-protected-resource"
    assert_response :success
    assert_equal "application/json", response.media_type
  end

  test "oauth authorization server discovery endpoint resolves" do
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    assert_equal "application/json", response.media_type
  end

  test "doorkeeper oauth authorize endpoint resolves" do
    get "/oauth/authorize"
    # Will redirect to login since unauthenticated
    assert_response :redirect
  end

  test "root path resolves" do
    get "/"
    # Root path should load (may show login or home depending on auth state)
    assert_includes [ 200, 302 ], response.status
  end
end
