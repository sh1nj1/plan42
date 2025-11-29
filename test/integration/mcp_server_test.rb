require "test_helper"

class McpServerTest < ActionDispatch::IntegrationTest
  setup do
    @application = Doorkeeper::Application.create!(
      name: "Test Client",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public"
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
    assert_nil response.headers["ETag"]
  end
end
