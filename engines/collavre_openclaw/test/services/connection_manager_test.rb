require "test_helper"

module CollavreOpenclaw
  class ConnectionManagerTest < ActiveSupport::TestCase
    setup do
      # Reset singleton state
      manager = ConnectionManager.instance
      manager.disconnect_all
    end

    test "connection_for creates a new client" do
      user = mock_user(id: 1)
      manager = ConnectionManager.instance

      client = manager.connection_for(user)
      assert_instance_of WebsocketClient, client
      assert_equal :disconnected, client.state
    end

    test "connection_for reuses existing client" do
      user = mock_user(id: 1)
      manager = ConnectionManager.instance

      client1 = manager.connection_for(user)
      client2 = manager.connection_for(user)
      assert_same client1, client2
    end

    test "connection_for shares client for users with same gateway_url" do
      user1 = mock_user(id: 1, gateway_url: "http://gateway1.local")
      user2 = mock_user(id: 2, gateway_url: "http://gateway1.local")
      manager = ConnectionManager.instance

      client1 = manager.connection_for(user1)
      client2 = manager.connection_for(user2)
      assert_same client1, client2, "Users with same gateway should share connection"
    end

    test "connection_for creates separate clients for users with different gateway_urls" do
      user1 = mock_user(id: 1, gateway_url: "http://gateway1.local")
      user2 = mock_user(id: 2, gateway_url: "http://gateway2.local")
      manager = ConnectionManager.instance

      client1 = manager.connection_for(user1)
      client2 = manager.connection_for(user2)
      refute_same client1, client2, "Users with different gateways should have separate connections"
    end

    test "disconnect removes user from shared connection" do
      user1 = mock_user(id: 1, gateway_url: "http://gateway1.local")
      user2 = mock_user(id: 2, gateway_url: "http://gateway1.local")
      manager = ConnectionManager.instance

      client = manager.connection_for(user1)
      manager.connection_for(user2)

      # Disconnect user1 - connection should stay because user2 is still using it
      manager.disconnect(user1)

      # user2 should still get the same client
      assert_same client, manager.connection_for(user2)
    end

    test "disconnect closes connection when last user disconnects" do
      user = mock_user(id: 1, gateway_url: "http://gateway1.local")
      manager = ConnectionManager.instance

      manager.connection_for(user)
      manager.disconnect(user)

      # Next call should create a new client
      new_client = manager.connection_for(user)
      assert_equal :disconnected, new_client.state
    end

    test "disconnect_all clears all connections" do
      user1 = mock_user(id: 1, gateway_url: "http://gateway1.local")
      user2 = mock_user(id: 2, gateway_url: "http://gateway2.local")
      manager = ConnectionManager.instance

      manager.connection_for(user1)
      manager.connection_for(user2)
      manager.disconnect_all

      status = manager.status
      assert_equal 0, status[:total_connections]
      assert_equal 0, status[:total_users]
    end

    test "status returns connection and user counts" do
      user1 = mock_user(id: 1, gateway_url: "http://gateway1.local")
      user2 = mock_user(id: 2, gateway_url: "http://gateway1.local")
      user3 = mock_user(id: 3, gateway_url: "http://gateway2.local")
      manager = ConnectionManager.instance

      manager.connection_for(user1)
      manager.connection_for(user2)
      manager.connection_for(user3)
      status = manager.status

      assert_equal 0, status[:connected]
      assert_equal 2, status[:disconnected]
      assert_equal 2, status[:total_connections], "2 gateways = 2 connections"
      assert_equal 3, status[:total_users], "3 users total"
    end

    test "connected_count returns zero when no connections" do
      manager = ConnectionManager.instance
      assert_equal 0, manager.connected_count
    end

    test "on_proactive_message applies handler to new connections" do
      manager = ConnectionManager.instance
      handler_called = false

      manager.on_proactive_message { |_user, _msg| handler_called = true }

      # New connection created AFTER handler registration should have it
      user = mock_user(id: 1)
      client = manager.connection_for(user)
      assert client.instance_variable_get(:@proactive_handler), "Handler should be set on new client"
    end

    test "has default proactive handler on initialization" do
      manager = ConnectionManager.instance
      assert manager.instance_variable_get(:@proactive_handler), "Default proactive handler should be set"
      assert_instance_of ProactiveMessageHandler, manager.instance_variable_get(:@proactive_message_handler)
    end

    test "default handler is applied to new connections" do
      manager = ConnectionManager.instance
      user = mock_user(id: 10)
      client = manager.connection_for(user)
      assert client.instance_variable_get(:@proactive_handler), "Default handler should be set on new client"
    end

    test "users_for_gateway returns correct count" do
      user1 = mock_user(id: 1, gateway_url: "http://gateway1.local")
      user2 = mock_user(id: 2, gateway_url: "http://gateway1.local")
      user3 = mock_user(id: 3, gateway_url: "http://gateway2.local")
      manager = ConnectionManager.instance

      manager.connection_for(user1)
      manager.connection_for(user2)
      manager.connection_for(user3)

      assert_equal 2, manager.users_for_gateway("http://gateway1.local")
      assert_equal 1, manager.users_for_gateway("http://gateway2.local")
      assert_equal 0, manager.users_for_gateway("http://unknown.local")
    end

    test "user_connected? returns false for disconnected state" do
      user = mock_user(id: 1)
      manager = ConnectionManager.instance

      manager.connection_for(user)
      # Client is in :disconnected state (not actually connected)
      refute manager.user_connected?(user)
    end

    test "fatal close callback removes dead client so next call creates fresh one" do
      user = mock_user(id: 1, gateway_url: "http://gateway1.local")
      manager = ConnectionManager.instance

      old_client = manager.connection_for(user)

      # Simulate the fatal close callback (which ConnectionManager wires up)
      manager.send(:handle_fatal_close, "http://gateway1.local", old_client)

      new_client = manager.connection_for(user)
      refute_same old_client, new_client, "Should create fresh client after fatal close"
    end

    test "new clients get fatal_close callback" do
      manager = ConnectionManager.instance
      user = mock_user(id: 1)
      client = manager.connection_for(user)

      assert client.instance_variable_get(:@on_fatal_close), "Fatal close callback should be set"
    end

    test "connection_for returns nil for blank gateway_url" do
      user = mock_user(id: 1, gateway_url: "")
      manager = ConnectionManager.instance

      client = manager.connection_for(user)
      assert_nil client
    end

    private

    def mock_user(id:, gateway_url: "http://localhost:18789")
      OpenStruct.new(
        id: id,
        gateway_url: gateway_url,
        llm_api_key: "test-token",
        email: "agent-#{id}@collavre.com"
      )
    end
  end
end
