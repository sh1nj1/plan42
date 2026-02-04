module CollavreOpenclaw
  # Manages per-user WebSocket connections to OpenClaw Gateways.
  #
  # Singleton: use ConnectionManager.instance
  #
  # Features:
  # - Lazy connect (creates connection on first use)
  # - Connection reuse (same user → same connection)
  # - Idle timeout (disconnects after inactivity)
  # - Thread-safe access
  # - Graceful shutdown
  class ConnectionManager
    include Singleton

    def initialize
      @connections = {} # user_id → WebsocketClient
      @mutex = Mutex.new
      @idle_checker = nil
      start_idle_checker!
    end

    # Get or create a WebSocket connection for a user.
    # The connection is lazily connected on first RPC call,
    # but you can call connect! explicitly if needed.
    #
    # @param user [User] must respond to #gateway_url and #llm_api_key
    # @return [WebsocketClient]
    def connection_for(user)
      @mutex.synchronize do
        client = @connections[user.id]
        if client.nil?
          client = WebsocketClient.new(user: user)
          client.on_proactive_message(&@proactive_handler) if @proactive_handler
          @connections[user.id] = client
        end
        client
      end
    end

    # Disconnect a specific user's connection
    def disconnect(user)
      @mutex.synchronize do
        client = @connections.delete(user.id)
        client&.disconnect!
      end
    end

    # Disconnect all connections (for app shutdown)
    def disconnect_all
      @mutex.synchronize do
        @connections.each_value(&:disconnect!)
        @connections.clear
      end
      stop_idle_checker!
    end

    # Number of active connections
    def connected_count
      @mutex.synchronize do
        @connections.count { |_, c| c.connected? }
      end
    end

    # Status summary
    def status
      @mutex.synchronize do
        states = @connections.values.group_by(&:state)
        {
          connected: states[:connected]&.size || 0,
          connecting: states[:connecting]&.size || 0,
          reconnecting: states[:reconnecting]&.size || 0,
          disconnected: states[:disconnected]&.size || 0,
          total: @connections.size
        }
      end
    end

    # Register a proactive message handler for all connections.
    # New connections will also get this handler.
    def on_proactive_message(&handler)
      @mutex.synchronize do
        @proactive_handler = handler
        @connections.each_value do |client|
          client.on_proactive_message(&handler)
        end
      end
    end

    private

    def start_idle_checker!
      @idle_checker = Thread.new do
        Thread.current.name = "openclaw-idle-checker"
        loop do
          sleep 60 # Check every minute
          check_idle_connections!
        rescue => e
          Rails.logger.error("[CollavreOpenclaw::ConnectionManager] Idle checker error: #{e.message}")
        end
      end
    end

    def stop_idle_checker!
      @idle_checker&.kill
      @idle_checker = nil
    end

    def check_idle_connections!
      timeout = CollavreOpenclaw.config.ws_idle_timeout

      @mutex.synchronize do
        @connections.each do |user_id, client|
          if client.connected? && client.idle_seconds > timeout
            Rails.logger.info("[CollavreOpenclaw::ConnectionManager] Disconnecting idle connection for user #{user_id}")
            client.disconnect!
            @connections.delete(user_id)
          end
        end
      end
    end
  end
end
