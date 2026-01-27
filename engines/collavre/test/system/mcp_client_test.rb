require_relative "../application_system_test_case"
require "net/http"
require "uri"
require "json"

class McpClientTest < ApplicationSystemTestCase
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
    ).token
  end

  test "full mcp flow with sse and messages" do
    # Get the server URL from Capybara
    # We need to visit a page to ensure the server is running and we have the port
    visit root_url

    base_url = Capybara.current_session.server_url
    sse_uri = URI.parse("#{base_url}/mcp/sse")
    messages_uri = URI.parse("#{base_url}/mcp/messages")

    sse_connected = false
    endpoint_received = false
    tools_list_received = false

    # Thread to listen to SSE
    sse_thread = Thread.new do
      Net::HTTP.start(sse_uri.host, sse_uri.port) do |http|
        request = Net::HTTP::Get.new(sse_uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "text/event-stream"

        http.request(request) do |response|
          sse_connected = true
          response.read_body do |chunk|
            if chunk.include?("endpoint")
              endpoint_received = true
            end
            if chunk.include?("tools")
              tools_list_received = true
            end
          end
        end
      end
    rescue => e
      puts "SSE Error: #{e.message}"
    end

    # Wait for SSE to connect
    Timeout.timeout(5) do
      sleep 0.1 until sse_connected
    end

    # Send POST request
    http = Net::HTTP.new(messages_uri.host, messages_uri.port)
    request = Net::HTTP::Post.new(messages_uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = {
      jsonrpc: "2.0",
      method: "tools/list",
      id: 1
    }.to_json

    response = http.request(request)
    assert_equal "200", response.code

    # Wait for response on SSE
    Timeout.timeout(10) do
      sleep 0.1 until tools_list_received
    end

    assert endpoint_received, "Should have received endpoint event"
    assert tools_list_received, "Should have received tools/list response via SSE"

    sse_thread.kill
  end
end
