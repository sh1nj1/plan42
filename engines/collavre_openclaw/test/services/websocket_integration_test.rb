require "test_helper"
require_relative "../support/mock_openclaw_gateway"

module CollavreOpenclaw
  class WebsocketIntegrationTest < ActiveSupport::TestCase
    setup do
      @gateway = MockOpenclawGateway.new(port: 0)
      @gateway.script = [
        { on: "connect", respond: :hello_ok }
      ]
      @gateway.start!

      @user = mock_user(
        id: 1,
        gateway_url: @gateway.url,
        llm_api_key: "test-token",
        email: "ai-agent@collavre.com"
      )

      # Reset ConnectionManager
      if ConnectionManager.instance_variable_get(:@singleton__instance__)
        ConnectionManager.instance.disconnect_all
      end
    end

    teardown do
      if ConnectionManager.instance_variable_get(:@singleton__instance__)
        ConnectionManager.instance.disconnect_all
      end
      @gateway&.stop!
    end

    # ─────────────────────────────────────────────
    # Full handshake + chat flow
    # ─────────────────────────────────────────────

    test "full handshake and chat send with streaming deltas" do
      @gateway.script = [
        { on: "connect", respond: :hello_ok },
        { on: "chat.send", respond: :stream_deltas, text: "Hello world from gateway" }
      ]

      client = WebsocketClient.new(user: @user)
      client.connect!

      assert client.connected?, "Should be connected after handshake"

      yielded = []
      result = client.chat_send(
        session_key: "test:session:1",
        message: "Hi there"
      ) do |event|
        yielded << event
      end

      assert_equal "Hello world from gateway", result
      deltas = yielded.select { |e| e[:state] == "delta" }
      finals = yielded.select { |e| e[:state] == "final" }
      assert deltas.size >= 1, "Should receive delta events"
      assert_equal 1, finals.size, "Should receive exactly one final event"

      client.disconnect!
    end

    # ─────────────────────────────────────────────
    # Auth failure → fatal close → no retry
    # ─────────────────────────────────────────────

    test "auth failure closes with fatal code and does not retry" do
      @gateway.script = [
        { on: "connect", respond: :auth_failure, code: 4001 }
      ]

      client = WebsocketClient.new(user: @user)

      assert_raises(CollavreOpenclaw::ConnectionError) do
        client.connect!
      end

      # Should NOT be in reconnecting state
      refute_equal :reconnecting, client.state
    end

    # ─────────────────────────────────────────────
    # Duplicate events are deduped
    # ─────────────────────────────────────────────

    test "duplicate broadcast+nodeSend events are deduplicated" do
      @gateway.script = [
        { on: "connect", respond: :hello_ok },
        { on: "chat.send", respond: :duplicate_events, text: "Hello" }
      ]

      client = WebsocketClient.new(user: @user)
      client.connect!

      yielded = []
      result = client.chat_send(
        session_key: "test:session:dedup",
        message: "Test"
      ) do |event|
        yielded << event
      end

      assert_equal "Hello", result

      # Should only get one delta and one final despite duplicates
      deltas = yielded.select { |e| e[:state] == "delta" }
      finals = yielded.select { |e| e[:state] == "final" }
      assert_equal 1, deltas.size, "Duplicate deltas should be deduped"
      assert_equal 1, finals.size, "Duplicate finals should be deduped"

      client.disconnect!
    end

    # ─────────────────────────────────────────────
    # Chat error from gateway
    # ─────────────────────────────────────────────

    test "chat error event raises ChatError" do
      @gateway.script = [
        { on: "connect", respond: :hello_ok },
        { on: "chat.send", respond: :error, error_message: "Model overloaded" }
      ]

      client = WebsocketClient.new(user: @user)
      client.connect!

      error_events = []
      assert_raises(CollavreOpenclaw::ChatError) do
        client.chat_send(
          session_key: "test:session:err",
          message: "Test"
        ) do |event|
          error_events << event if event[:state] == "error"
        end
      end

      assert_equal 1, error_events.size

      client.disconnect!
    end

    # ─────────────────────────────────────────────
    # Chat history
    # ─────────────────────────────────────────────

    test "chat_history returns response" do
      @gateway.script = [
        { on: "connect", respond: :hello_ok }
      ]

      client = WebsocketClient.new(user: @user)
      client.connect!

      result = client.chat_history(session_key: "test:session:history")
      assert_not_nil result
      assert result.key?(:messages) || result.key?(:sessionKey)

      client.disconnect!
    end

    # ─────────────────────────────────────────────
    # Connection via ConnectionManager
    # ─────────────────────────────────────────────

    test "ConnectionManager creates and shares connections" do
      @gateway.script = [
        { on: "connect", respond: :hello_ok }
      ]

      manager = ConnectionManager.instance
      client = manager.connection_for(@user)

      assert_instance_of WebsocketClient, client

      # Second call should return same client
      client2 = manager.connection_for(@user)
      assert_same client, client2

      manager.disconnect(@user)
    end

    # ─────────────────────────────────────────────
    # Close-code policy integration
    # ─────────────────────────────────────────────

    test "close_policy constant is accessible" do
      client = WebsocketClient.new(user: @user)
      assert_equal :fatal, client.send(:close_policy, 4001)
      assert_equal :reconnect, client.send(:close_policy, 1006)
      assert_equal :normal, client.send(:close_policy, 1000)
    end

    private

    def mock_user(id:, gateway_url:, llm_api_key:, email:)
      OpenStruct.new(
        id: id,
        gateway_url: gateway_url,
        llm_api_key: llm_api_key,
        email: email
      )
    end
  end
end
