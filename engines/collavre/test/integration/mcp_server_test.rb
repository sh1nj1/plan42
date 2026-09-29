require "test_helper"

class McpServerTest < ActionDispatch::IntegrationTest
  setup do
    @application = Doorkeeper::Application.create!(
      name: "Test Client",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public",
      owner: users(:one)
    )
    @token = Doorkeeper::AccessToken.create!(
      application: @application,
      resource_owner_id: users(:one).id,
      scopes: "public"
    )
  end

  test "mcp sse endpoint requires authentication" do
    get "/mcp/sse"
    assert_response :unauthorized
    assert_equal 'Bearer realm="Doorkeeper"', response.headers["WWW-Authenticate"]
  end

  test "mcp sse endpoint is available with valid token" do
    get "/mcp/sse", headers: { "Authorization" => "Bearer #{@token.token}" }
    assert_response :success
    assert_equal "text/event-stream", response.content_type
    assert_equal "no-cache", response.headers["Cache-Control"]
  end

  test "mcp messages endpoint requires authentication" do
    post "/mcp/messages", params: { jsonrpc: "2.0", method: "ping", id: 1 }.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "mcp messages endpoint accepts valid token" do
    post "/mcp/messages",
      params: { jsonrpc: "2.0", method: "ping", id: 1 }.to_json,
      headers: {
        "Authorization" => "Bearer #{@token.token}",
        "Content-Type" => "application/json"
      }
    assert_response :success
  end
  test "an mcp tools/call is recorded once as an mcp tool usage" do
    post "/mcp/messages",
      params: { jsonrpc: "2.0", method: "tools/call", id: 2, params: { name: "cron_list", arguments: {} } }.to_json,
      headers: { "Authorization" => "Bearer #{@token.token}", "Content-Type" => "application/json" }
    assert_response :success

    usage = Collavre::ToolUsage.sole
    assert_equal [ "mcp", "cron_list", true ], [ usage.source, usage.tool_name, usage.succeeded ]
    assert_equal [ users(:one).id ], usage.requester_ids
  end

  test "agent token rejects unselected direct and nested tools and accepts selected tools" do
    agent = users(:ai_bot)
    agent.update!(tools: %w[meta_tool cron_list])
    @token.update!(resource_owner_id: agent.id)
    assert_mcp_denied("cron_cancel", { key: "missing" })
    assert_mcp_denied("meta_tool", { action: "run", tool_name: "cron_cancel", arguments: { key: "missing" } })
    assert_mcp_denied("meta_tool", { action: "run", tool_name: "meta_tool", arguments: {
      action: "call", tool_name: "cron_cancel", arguments: { key: "missing" }
    } })
    call_mcp("cron_list")
    assert Collavre::ToolUsage.last.succeeded
    agent.update!(tools: [])
    assert_mcp_denied("cron_list")
    refute Collavre::ToolUsage.last.succeeded
  end

  test "per-user workspace callback token enforces the agent selection instead of human token owner" do
    gateway = Collavre::AgentGateway.create!(owner: users(:one), name: "Permission test",
      base_url: "https://proxy.example.com", admin_key: "admin", completion_key: "completion",
      identity_secret: "p" * 32, workspace_mode: :per_user)
    agent = users(:ai_bot)
    agent.update!(created_by_id: users(:one).id, llm_vendor: "cli_proxy", agent_gateway: gateway, tools: %w[meta_tool cron_list])
    workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: users(:one))
    @token = Doorkeeper::AccessToken.find(workspace.callback_access_token_id)
    @bearer = workspace.callback_token
    assert_equal users(:one).id, @token.resource_owner_id
    assert_mcp_denied("cron_cancel", { key: "missing" })
    assert_mcp_denied("meta_tool", { action: "run", tool_name: "cron_cancel", arguments: { key: "missing" } })
    call_mcp("cron_list")
    assert Collavre::ToolUsage.last.succeeded
    agent.update!(tools: [])
    assert_mcp_denied("cron_list")
  end

  private

  def call_mcp(name, arguments = {})
    post "/mcp/messages",
      params: { jsonrpc: "2.0", method: "tools/call", id: 3, params: { name: name, arguments: arguments } }.to_json,
      headers: { "Authorization" => "Bearer #{@bearer || @token.token}", "Content-Type" => "application/json" }
    assert_response :success
  end

  def assert_mcp_denied(name, arguments = {})
    Collavre::Tools::CronCancelService.stub(:new, -> { flunk "Denied tool must not execute" }) do
      call_mcp(name, arguments)
    end
    assert_equal name, Collavre::ToolUsage.last.tool_name
    refute Collavre::ToolUsage.last.succeeded
  end
end
