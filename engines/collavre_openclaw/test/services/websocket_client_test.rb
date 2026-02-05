require "test_helper"

module CollavreOpenclaw
  class WebsocketClientTest < ActiveSupport::TestCase
    setup do
      @user = mock_user(
        id: 1,
        gateway_url: "http://localhost:18789",
        llm_api_key: "test-token",
        email: "ai-agent@collavre.com"
      )
    end

    test "initializes in disconnected state" do
      client = WebsocketClient.new(user: @user)
      assert_equal :disconnected, client.state
      assert_not client.connected?
    end

    test "requires gateway_url" do
      user = mock_user(id: 2, gateway_url: nil, llm_api_key: "token", email: "test@test.com")
      client = WebsocketClient.new(user: user)

      assert_raises(CollavreOpenclaw::ConnectionError) do
        client.connect!
      end
    end

    test "gateway_ws_url converts http to ws" do
      client = WebsocketClient.new(user: @user)
      url = client.send(:gateway_ws_url)
      assert_equal "ws://localhost:18789/", url
    end

    test "gateway_ws_url converts https to wss" do
      user = mock_user(
        id: 3,
        gateway_url: "https://gateway.example.com:18789",
        llm_api_key: "token",
        email: "test@test.com"
      )
      client = WebsocketClient.new(user: user)
      url = client.send(:gateway_ws_url)
      assert_equal "wss://gateway.example.com:18789/", url
    end

    test "gateway_ws_url preserves ws scheme" do
      user = mock_user(
        id: 4,
        gateway_url: "ws://localhost:18789",
        llm_api_key: "token",
        email: "test@test.com"
      )
      client = WebsocketClient.new(user: user)
      url = client.send(:gateway_ws_url)
      assert_equal "ws://localhost:18789/", url
    end

    test "extract_event_text handles string content" do
      client = WebsocketClient.new(user: @user)
      event = { message: { role: "assistant", content: "Hello world" } }
      assert_equal "Hello world", client.send(:extract_event_text, event)
    end

    test "extract_event_text handles array content" do
      client = WebsocketClient.new(user: @user)
      event = {
        message: {
          role: "assistant",
          content: [
            { type: "text", text: "Hello " },
            { type: "text", text: "world" }
          ]
        }
      }
      assert_equal "Hello world", client.send(:extract_event_text, event)
    end

    test "extract_event_text returns nil for non-hash message" do
      client = WebsocketClient.new(user: @user)
      assert_nil client.send(:extract_event_text, { message: "raw string" })
    end

    test "extract_agent_id from email" do
      client = WebsocketClient.new(user: @user)
      assert_equal "ai-agent", client.send(:extract_agent_id)
    end

    test "idle_seconds returns infinity when never active" do
      client = WebsocketClient.new(user: @user)
      assert_equal Float::INFINITY, client.idle_seconds
    end

    test "disconnect clears pending requests and runs" do
      client = WebsocketClient.new(user: @user)
      client.disconnect!
      assert_equal :disconnected, client.state
    end

    private

    def mock_user(id:, gateway_url:, llm_api_key:, email:)
      user = OpenStruct.new(
        id: id,
        gateway_url: gateway_url,
        llm_api_key: llm_api_key,
        email: email
      )
      user
    end
  end
end
