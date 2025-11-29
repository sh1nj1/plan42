require "test_helper"

class McpDiscoveryTest < ActionDispatch::IntegrationTest
  test "oauth protected resource metadata is available" do
    get "/.well-known/oauth-protected-resource"
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "http://www.example.com/mcp", json["resource"]
    assert_equal ["http://www.example.com"], json["authorization_servers"]
    assert_equal ["public"], json["scopes_supported"]
  end

  test "oauth authorization server metadata is available" do
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "http://www.example.com", json["issuer"]
    assert_equal "http://www.example.com/oauth/authorize", json["authorization_endpoint"]
    assert_equal "http://www.example.com/oauth/token", json["token_endpoint"]
  end
end
