module CollavreOpenclaw
  # Manages WebSocket connections to OpenClaw Gateways.
  #
  # Singleton: use ConnectionManager.instance
  #
  # Features:
  # - Lazy connect (creates connection on first use)
  # - Connection sharing (same gateway_url → same connection)
  # - Idle timeout (disconnects after inactivity)
  # - Thread-safe access
  # - Graceful shutdown
  #
  # Multiple AI agents using the same Gateway share a single WebSocket
  # connection, reducing resource usage and connection overhead.
  class ConnectionManager
    include Singleton

    def initialize
      @connections = {} # gateway_url → WebsocketClient
      @gateway_users = {} # gateway_url → Set<user_id> (users sharing this gateway)
      @user_gateways = {} # user_id → gateway_url (reverse lookup)
      @mutex = Mutex.new
      @idle_checker = nil
      @proactive_handler = nil
      @proactive_message_handler = ProactiveMessageHandler.new
      setup_default_proactive_handler!
      start_idle_checker!
    end

    # Get or create a WebSocket connection for a user.
    # Users with the same gateway_url share a single connection.
    #
    # @param user [User] must respond to #gateway_url and #llm_api_key
    # @return [WebsocketClient]
    def connection_for(user)
      gateway_url = user.gateway_url.to_s.strip
      if gateway_url.blank?
        Rails.logger.warn("[CollavreOpenclaw::ConnectionManager] User #{user.id} has blank gateway_url, cannot create connection")
        return nil
      end

      @mutex.synchronize do
        client = @connections[gateway_url]

        if client.nil?
          client = create_client(user, gateway_url)
        end

        # Track this user as using this gateway
        @gateway_users[gateway_url].add(user.id)
        @user_gateways[user.id] = gateway_url

        client
      end
    end

    # Disconnect a specific user from their gateway connection.
    # The connection is only closed if no other users are sharing it.
    def disconnect(user)
      @mutex.synchronize do
        gateway_url = @user_gateways.delete(user.id)
        return unless gateway_url

        users = @gateway_users[gateway_url]
        users&.delete(user.id)

        # Only disconnect if no users are sharing this gateway
        if users.nil? || users.empty?
          client = @connections.delete(gateway_url)
          @gateway_users.delete(gateway_url)
          client&.disconnect!
        end
      end
    end

    # Disconnect all connections (for app shutdown)
    def disconnect_all
      @mutex.synchronize do
        @connections.each_value(&:disconnect!)
        @connections.clear
        @gateway_users.clear
        @user_gateways.clear
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
          total_connections: @connections.size,
          total_users: @user_gateways.size
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

    # Get the number of users sharing a specific gateway
    def users_for_gateway(gateway_url)
      @mutex.synchronize do
        @gateway_users[gateway_url]&.size || 0
      end
    end

    # Check if a user has an active connection
    def user_connected?(user)
      @mutex.synchronize do
        gateway_url = @user_gateways[user.id]
        return false unless gateway_url
        @connections[gateway_url]&.connected? || false
      end
    end

    private

    # Create a new WebsocketClient and wire up handlers.
    def create_client(user, gateway_url)
      client = WebsocketClient.new(user: user)
      client.on_proactive_message(&@proactive_handler) if @proactive_handler
      client.on_fatal_close do |dead_client|
        handle_fatal_close(gateway_url, dead_client)
      end
      @connections[gateway_url] = client
      @gateway_users[gateway_url] ||= Set.new
      client
    end

    # Called when a client receives a fatal close code (auth failure, etc.).
    # Removes the dead client so the next connection_for call creates a fresh one.
    #
    # Guard: only deletes if the current mapping still points to dead_client.
    # Without this, a late-arriving callback from an old client could wipe a
    # new live connection that was already registered for the same gateway_url.
    def handle_fatal_close(gateway_url, dead_client)
      @mutex.synchronize do
        return unless @connections[gateway_url].equal?(dead_client)

        Rails.logger.warn("[CollavreOpenclaw::ConnectionManager] Fatal close for gateway #{gateway_url}, removing connection")
        @connections.delete(gateway_url)
        user_ids = @gateway_users.delete(gateway_url) || Set.new
        user_ids.each { |uid| @user_gateways.delete(uid) }
      end
    end

    # Set up the default proactive message handler that dispatches
    # unsolicited chat events to CallbackProcessorJob.
    def setup_default_proactive_handler!
      handler = @proactive_message_handler
      on_proactive_message do |user, payload|
        handler.handle(user, payload)
      end
    end

    def start_idle_checker!
      @idle_checker_stop = false
      @idle_checker = Thread.new do
        Thread.current.name = "openclaw-idle-checker"
        loop do
          break if @idle_checker_stop
          sleep 1 # Check stop flag every second
          @idle_check_counter = (@idle_check_counter || 0) + 1
          next unless @idle_check_counter >= 60 # Run check every ~60 seconds
          @idle_check_counter = 0
          check_idle_connections!
        rescue => e
          Rails.logger.error("[CollavreOpenclaw::ConnectionManager] Idle checker error: #{e.message}")
        end
      end
    end

    def stop_idle_checker!
      @idle_checker_stop = true
      @idle_checker&.join(5)
      @idle_checker = nil
    end

    def check_idle_connections!
      timeout = CollavreOpenclaw.config.ws_idle_timeout

      @mutex.synchronize do
        idle_gateways = @connections.each_with_object([]) do |(gateway_url, client), urls|
          urls << gateway_url if client.connected? && client.idle_seconds > timeout
        end

        idle_gateways.each do |gateway_url|
          client = @connections.delete(gateway_url)
          user_ids = @gateway_users.delete(gateway_url) || []
          user_ids.each { |uid| @user_gateways.delete(uid) }
          user_count = user_ids.size
          Rails.logger.info("[CollavreOpenclaw::ConnectionManager] Disconnecting idle connection for gateway #{gateway_url} (#{user_count} users)")
          client&.disconnect!
        end
      end
    end
  end
end
