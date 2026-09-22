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

  test "marks requests made with a workspace callback token by token id, not application name" do
    marks = []
    probe = ->(_env) { marks << Collavre::Current.mcp_agent_workspace; [ 200, {}, [] ] }
    middleware = McpOauthMiddleware.new(probe)
    workspace = create_workspace
    callback = Doorkeeper::AccessToken.find(workspace.callback_access_token_id)
    callback.application.update!(name: "Renamed by owner")
    lookalike_app = Doorkeeper::Application.create!(name: Collavre::AgentWorkspace::CALLBACK_APPLICATION_NAME, redirect_uri: "urn:ietf:wg:oauth:2.0:oob", owner: @user, confidential: true, scopes: "public")
    lookalike = Doorkeeper::AccessToken.create!(application: lookalike_app, resource_owner_id: @user.id, scopes: "public")

    [ workspace.callback_token, lookalike.token, @token.token ].each do |bearer|
      Collavre::Current.reset
      middleware.call(Rack::MockRequest.env_for("/mcp/messages", "HTTP_AUTHORIZATION" => "Bearer #{bearer}"))
    end

    assert_equal [ workspace, nil, nil ], marks
  ensure
    Collavre::Current.reset
  end

  private

  def create_workspace
    gateway = Collavre::AgentGateway.create!(owner: @user, name: "MCP proxy", base_url: "https://proxy.example.com",
      admin_key: "admin", completion_key: "completion", identity_secret: "m" * 32, workspace_mode: :shared)
    agent = Collavre::User.create!(name: "MCP Agent", email: "mcp-workspace-agent@ai.local", password: SecureRandom.hex(24),
      system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @user.id, agent_gateway: gateway)
    Collavre::AgentWorkspace.resolve!(agent: agent, user: @user)
  end
end
