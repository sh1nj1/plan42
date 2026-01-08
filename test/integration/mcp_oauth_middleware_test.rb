require "test_helper"

class McpOauthMiddlewareTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @application = Doorkeeper::Application.create!(name: "Test App", redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @user, confidential: true, scopes: "public")
    @token = Doorkeeper::AccessToken.create!(application: @application, resource_owner_id: @user.id, scopes: "public")
  end

  test "should allow access with valid token using middleware logic" do
    # A 404 response confirms the middleware authenticated successfully and passed
    # the request to the Rails app (which then couldn't find the route).
    # If the middleware had failed authentication, it would have returned 401.
    get "/mcp/test", headers: { "Authorization" => "Bearer #{@token.token}" }
    assert_response :not_found, "Authenticated requests to non-existent routes should return 404, verifying middleware passed."
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

  test "should allow valid token on sse path" do
      # Verify that a valid token does not result in a 401 Unauthorized response.
      # We check against /mcp/sse specifically as it's handled specially by the middleware.
      get "/mcp/sse", headers: { "Authorization" => "Bearer #{@token.token}" }
      assert_not_equal 401, response.status
  end
end
