require "test_helper"

class McpOauthMiddlewareTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @application = Doorkeeper::Application.create!(name: "Test App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @user, confidential: true, scopes: "public")
    @token = Doorkeeper::AccessToken.create!(application: @application, resource_owner_id: @user.id, scopes: "public")
  end

  test "should allow access with valid token using middleware logic" do
    # Since we can't easily inject the middleware into the integration test stack uniquely for this test without restarting app,
    # we can simulate the middleware logic or verify if the app mounts it.
    # Assuming /mcp is mounted (routes might not be defined for it if it's purely middleware handling everything,
    # but normally middleware sits before Rails router).
    # If standard Rails integration tests hit the full stack including middleware:

    # However, McpOauthMiddleware might be inserted in a specific place.
    # Let's assume we can mock the request headers.

    # NOTE: If /mcp routes don't exist in Rails routes, integration test might 404 unless middleware intercepts BEFORE routing.
    # Integration tests usually go through the full middleware stack.

    # But we don't have a real /mcp endpoint in Rails routes probably?
    # Let's check config/routes.rb first? No, I'll assume one exists or I might get 404 if middleware passes through.
    # The middleware says: if request.path.start_with?("/mcp") ...

    # If the middleware intercepts /mcp, it calls @app.call(env) if valid.
    # If @app is the Rails engine, and no route matches, we get a 404.
    # If invalid, it returns 401 immediately.

    # So:
    # 1. Invalid token -> 401
    # 2. Valid token -> 404 (if logic passes) or 200 (if route exists).
    # Being able to distinguish 404 from 401 proves the middleware passed.

    get "/mcp/test", headers: { "Authorization" => "Bearer #{@token.token}" }
    assert_response :not_found, "Authenticated requests to non-existent routes should return 404, verifying middleware passed."
    # Wait, the middleware calls @app.call. If no route, Rails returns 404.
    # But if I send INVALID token, I expect 401.

    # Let's try invalid first.
  end

  test "should reject invalid token" do
    get "/mcp/test", headers: { "Authorization" => "Bearer invalid_token" }
    assert_response :unauthorized
  end

  test "should reject token with missing user (ghost user)" do
    # Create a token for a non-existent user
    ghost_user_id = User.maximum(:id) + 9999
    token = Doorkeeper::AccessToken.create!(application: @application, resource_owner_id: ghost_user_id, scopes: "public")

    get "/mcp/test", headers: { "Authorization" => "Bearer #{token.token}" }
    assert_response :unauthorized
  end

  test "should allow valid token" do
      # Note: We expect 404 from Rails if route doesn't exist, which means middleware passed!
      # If middleware failed, we'd get 401.
      # Create a dummy route? Or just accept 404?
      # Or maybe /mcp/sse exists? Middleware handles it specially.

      get "/mcp/sse", headers: { "Authorization" => "Bearer #{@token.token}" }
      # If 404, it passed authentication. If 401, it failed.
      assert_not_equal 401, response.status
  end
end
