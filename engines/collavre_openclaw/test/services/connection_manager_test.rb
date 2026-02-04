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

    test "connection_for creates separate clients for different users" do
      user1 = mock_user(id: 1)
      user2 = mock_user(id: 2)
      manager = ConnectionManager.instance

      client1 = manager.connection_for(user1)
      client2 = manager.connection_for(user2)
      refute_same client1, client2
    end

    test "disconnect removes user connection" do
      user = mock_user(id: 1)
      manager = ConnectionManager.instance

      manager.connection_for(user)
      manager.disconnect(user)

      # Next call should create a new client
      new_client = manager.connection_for(user)
      assert_equal :disconnected, new_client.state
    end

    test "disconnect_all clears all connections" do
      user1 = mock_user(id: 1)
      user2 = mock_user(id: 2)
      manager = ConnectionManager.instance

      manager.connection_for(user1)
      manager.connection_for(user2)
      manager.disconnect_all

      status = manager.status
      assert_equal 0, status[:total]
    end

    test "status returns connection counts" do
      user = mock_user(id: 1)
      manager = ConnectionManager.instance

      manager.connection_for(user)
      status = manager.status

      assert_equal 0, status[:connected]
      assert_equal 1, status[:disconnected]
      assert_equal 1, status[:total]
    end

    test "connected_count returns zero when no connections" do
      manager = ConnectionManager.instance
      assert_equal 0, manager.connected_count
    end

    test "on_proactive_message applies handler to new connections" do
      manager = ConnectionManager.instance
      handler_called = false

      manager.on_proactive_message { |_msg| handler_called = true }

      # New connection created AFTER handler registration should have it
      user = mock_user(id: 1)
      client = manager.connection_for(user)
      assert client.instance_variable_get(:@proactive_handler), "Handler should be set on new client"
    end

    private

    def mock_user(id:)
      OpenStruct.new(
        id: id,
        gateway_url: "http://localhost:18789",
        llm_api_key: "test-token",
        email: "agent-#{id}@collavre.com"
      )
    end
  end
end
