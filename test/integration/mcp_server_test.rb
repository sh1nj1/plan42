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
end
