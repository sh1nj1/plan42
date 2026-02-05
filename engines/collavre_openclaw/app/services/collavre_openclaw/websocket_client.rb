require "faye/websocket"
require "json"
require "securerandom"

module CollavreOpenclaw
  # WebSocket client for a single user's OpenClaw Gateway connection.
  #
  # Handles:
  # - Connection lifecycle (connect, disconnect, reconnect)
  # - OpenClaw protocol handshake (connect.challenge → connect → hello-ok)
  # - RPC request/response (chat.send, chat.history, chat.abort)
  # - Event streaming (chat events with delta/final/error states)
  # - Proactive message detection (unsolicited chat events)
  # - Tick keepalive
  #
  # Thread model:
  # - WebSocket runs in the shared EventMachine reactor thread
  # - Rails threads call public methods which bridge via EM.next_tick + Queue
  class WebsocketClient
    PROTOCOL_VERSION = 3

    attr_reader :user, :state

    # States: :disconnected, :connecting, :connected, :reconnecting
    def initialize(user:)
      @user = user
      @state = :disconnected
      @ws = nil
      @mutex = Mutex.new
      @connect_mutex = Mutex.new
      @connect_waiters = []   # Queues for threads waiting on in-progress connect
      @pending_requests = {}  # id → { queue:, timer: }
      @pending_runs = {}      # runId → Queue (for chat.send streaming)
      @proactive_handler = nil
      @reconnect_attempts = 0
      @last_activity_at = nil
      @tick_interval_ms = 15_000
      @tick_timer = nil
    end

    def connected?
      @state == :connected
    end

    # Connect to the Gateway. Blocks until connected or raises on failure.
    # Thread-safe: concurrent callers all wait on the same handshake attempt.
    def connect!
      return if connected?

      initiator = false
      waiter_queue = nil

      @connect_mutex.synchronize do
        return if connected?

        if @state == :connecting
          # Another thread is already connecting — wait on the same handshake
          waiter_queue = Queue.new
          @connect_waiters << waiter_queue
        else
          @state = :connecting
          initiator = true
        end
      end

      if waiter_queue
        # Wait for the initiating thread to finish handshake
        result = wait_with_timeout(waiter_queue, config.ws_connect_timeout, "connect (waiting)")
        if result[:error]
          raise ConnectionError, result[:error]
        end
        return result
      end

      # This thread initiates the connection
      queue = Queue.new

      EmReactor.next_tick do
        begin
          do_connect!(queue)
        rescue => e
          queue.push({ error: e.message })
        end
      end

      result = wait_with_timeout(queue, config.ws_connect_timeout, "connect")

      # Notify all waiting threads
      @connect_mutex.synchronize do
        if result[:error]
          @state = :disconnected
        else
          @state = :connected
          @reconnect_attempts = 0
          touch_activity!
        end

        @connect_waiters.each { |q| q.push(result) }
        @connect_waiters.clear
      end

      if result[:error]
        raise ConnectionError, result[:error]
      end

      result
    end

    # Disconnect gracefully
    def disconnect!
      @state = :disconnected
      EmReactor.next_tick do
        cancel_tick_timer!
        @ws&.close
        @ws = nil
      end
      # Unblock any waiting requests
      @pending_requests.each_value { |pr| pr[:queue]&.push({ error: "disconnected" }) }
      @pending_requests.clear
      @pending_runs.each_value { |q| q.push({ done: true }) }
      @pending_runs.clear
    end

    # Send a chat message. Blocks and yields streaming events.
    #
    # @param session_key [String]
    # @param message [String]
    # @param idempotency_key [String]
    # @yield [Hash] chat events with :state, :text, :message keys
    # @return [String, nil] final response text
    def chat_send(session_key:, message:, idempotency_key: nil, &block)
      ensure_connected!
      touch_activity!

      idempotency_key ||= SecureRandom.uuid
      actual_run_id = nil
      run_queue = Queue.new
      response_text = +""

      # Pre-register with idempotency_key to catch early events
      @mutex.synchronize { @pending_runs[idempotency_key] = run_queue }

      # Send the RPC request to get the real runId
      response = send_rpc("chat.send", {
        sessionKey: session_key,
        message: message,
        idempotencyKey: idempotency_key
      })

      # Re-register with the Gateway-assigned runId
      actual_run_id = response&.dig(:runId) || idempotency_key
      if actual_run_id != idempotency_key
        @mutex.synchronize do
          @pending_runs.delete(idempotency_key)
          @pending_runs[actual_run_id] = run_queue
        end
      end

      # Stream events until final/error/aborted
      loop do
        event = wait_with_timeout(run_queue, config.read_timeout, "chat response")

        break if event[:done]

        if event[:error]
          raise ChatError, event[:error]
        end

        case event[:state]
        when "delta"
          text = extract_event_text(event)
          if text.present?
            response_text << text
            yield({ state: "delta", text: text }) if block_given?
          end
        when "final"
          text = extract_event_text(event)
          yield({ state: "final", text: text, message: event[:message] }) if block_given?
          break
        when "error"
          error_msg = event[:errorMessage] || "Unknown error"
          yield({ state: "error", text: error_msg }) if block_given?
          raise ChatError, error_msg
        when "aborted"
          yield({ state: "aborted" }) if block_given?
          break
        end
      end

      response_text.presence
    ensure
      @mutex.synchronize do
        @pending_runs.delete(actual_run_id) if actual_run_id
        # Also clean up idempotency_key if send_rpc failed before we got a runId
        @pending_runs.delete(idempotency_key) if idempotency_key
      end
    end

    # Fetch chat history for a session
    def chat_history(session_key:, limit: nil)
      ensure_connected!
      touch_activity!

      params = { sessionKey: session_key }
      params[:limit] = limit if limit
      send_rpc("chat.history", params)
    end

    # Abort a running chat
    def chat_abort(session_key:, run_id: nil)
      ensure_connected!
      touch_activity!

      params = { sessionKey: session_key }
      params[:runId] = run_id if run_id
      send_rpc("chat.abort", params)
    end

    # Register a handler for proactive messages (unsolicited chat events)
    def on_proactive_message(&handler)
      @proactive_handler = handler
    end

    # Time since last activity (for idle timeout)
    def idle_seconds
      return Float::INFINITY unless @last_activity_at
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_activity_at
    end

    private

    def config
      CollavreOpenclaw.config
    end

    def gateway_ws_url
      url = @user.gateway_url.to_s.strip
      return nil if url.blank?

      uri = URI.parse(url)
      # Convert http(s) to ws(s)
      case uri.scheme
      when "https" then uri.scheme = "wss"
      when "http"  then uri.scheme = "ws"
      when "ws", "wss" then # already correct
      else
        uri.scheme = "ws"
      end
      uri.path = "/" if uri.path.blank?
      uri.to_s
    end

    def do_connect!(result_queue)
      url = gateway_ws_url
      unless url.present?
        result_queue.push({ error: "No Gateway URL configured" })
        return
      end

      @ws = Faye::WebSocket::Client.new(url)
      @handshake_queue = result_queue
      @handshake_done = false

      @ws.on :open do |_event|
        Rails.logger.info("[CollavreOpenclaw::WS] Connected to #{url}")
        # Wait for connect.challenge from gateway
      end

      @ws.on :message do |event|
        handle_raw_message(event.data)
      end

      @ws.on :close do |event|
        code = event.code
        reason = event.reason
        Rails.logger.info("[CollavreOpenclaw::WS] Disconnected (code=#{code}, reason=#{reason})")

        cancel_tick_timer!

        unless @handshake_done
          @handshake_done = true
          @handshake_queue&.push({ error: "Connection closed during handshake (code=#{code})" })
        end

        if @state == :connected
          @state = :reconnecting
          schedule_reconnect!
        end
      end
    end

    def handle_raw_message(data)
      frame = JSON.parse(data, symbolize_names: true)

      case frame[:type]
      when "event"
        handle_event(frame[:event], frame[:payload])
      when "res"
        handle_response(frame[:id], frame[:ok], frame[:payload], frame[:error])
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("[CollavreOpenclaw::WS] Invalid JSON: #{e.message}")
    end

    def handle_event(event_name, payload)
      case event_name
      when "connect.challenge"
        # Respond with connect request
        send_connect_request(payload)
      when "chat"
        handle_chat_event(payload)
      when "tick"
        handle_tick(payload)
      end
    end

    def send_connect_request(challenge_payload)
      agent_id = extract_agent_id
      device_id = "collavre-#{@user.id}-#{Digest::SHA256.hexdigest(@user.id.to_s)[0..7]}"

      params = {
        minProtocol: PROTOCOL_VERSION,
        maxProtocol: PROTOCOL_VERSION,
        client: {
          id: "collavre",
          version: CollavreOpenclaw::VERSION,
          platform: "ruby",
          mode: "operator"
        },
        role: "operator",
        scopes: [ "operator.read", "operator.write" ],
        caps: [],
        commands: [],
        permissions: {},
        auth: { token: @user.llm_api_key },
        locale: "en-US",
        userAgent: "collavre-openclaw/#{CollavreOpenclaw::VERSION}",
        device: {
          id: device_id
        }
      }

      request_id = SecureRandom.uuid
      send_frame({
        type: "req",
        id: request_id,
        method: "connect",
        params: params
      })

      # Store the request so hello-ok resolves the handshake
      @connect_request_id = request_id
    end

    def handle_response(id, ok, payload, error)
      # Check if this is the connect handshake response
      if id == @connect_request_id && !@handshake_done
        @handshake_done = true
        if ok
          @tick_interval_ms = payload&.dig(:policy, :tickIntervalMs) || 15_000
          @state = :connected
          @reconnect_attempts = 0
          start_tick_timer!
          @handshake_queue&.push({ ok: true, payload: payload })
        else
          error_msg = error&.dig(:message) || error.to_s || "handshake failed"
          @handshake_queue&.push({ error: error_msg })
        end
        @handshake_queue = nil
        return
      end

      # Regular RPC response
      pending = @mutex.synchronize { @pending_requests.delete(id) }
      if pending
        if ok
          pending[:queue].push({ ok: true, payload: payload })
        else
          error_msg = error&.dig(:message) || error.to_s || "RPC error"
          pending[:queue].push({ error: error_msg })
        end
      end
    end

    def handle_chat_event(payload)
      run_id = payload[:runId]

      # Check if this is a response to a pending chat.send
      run_queue = @mutex.synchronize { @pending_runs[run_id] }

      if run_queue
        # Known run — forward to the waiting thread
        run_queue.push(payload)
      elsif @proactive_handler
        # Unknown run — proactive message from Gateway (cron/heartbeat)
        Rails.logger.info("[CollavreOpenclaw::WS] Proactive message received (runId=#{run_id})")
        @proactive_handler.call(payload)
      else
        Rails.logger.debug("[CollavreOpenclaw::WS] Ignoring chat event for unknown runId=#{run_id}")
      end
    end

    def handle_tick(_payload)
      # Respond with a tick acknowledgment (poll response)
      send_frame({
        type: "req",
        id: SecureRandom.uuid,
        method: "poll",
        params: {}
      })
    end

    def start_tick_timer!
      cancel_tick_timer!
      interval = @tick_interval_ms / 1000.0
      @tick_timer = EM.add_periodic_timer(interval) do
        # Send keepalive poll if the server hasn't sent a tick
        send_frame({
          type: "req",
          id: SecureRandom.uuid,
          method: "poll",
          params: {}
        })
      end
    end

    def cancel_tick_timer!
      @tick_timer&.cancel
      @tick_timer = nil
    end

    # Send an RPC request and block until the response.
    # Returns the response payload.
    def send_rpc(method, params)
      request_id = SecureRandom.uuid
      queue = Queue.new

      @mutex.synchronize do
        @pending_requests[request_id] = { queue: queue }
      end

      EmReactor.next_tick do
        send_frame({
          type: "req",
          id: request_id,
          method: method,
          params: params
        })
      end

      result = wait_with_timeout(queue, config.read_timeout, method)
      if result[:error]
        raise RpcError, "#{method} failed: #{result[:error]}"
      end
      result[:payload]
    ensure
      @mutex.synchronize { @pending_requests.delete(request_id) }
    end

    def send_frame(frame)
      return unless @ws

      data = JSON.generate(frame)
      @ws.send(data)
    end

    def ensure_connected!
      unless connected?
        connect!
      end
    end

    def touch_activity!
      @last_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def schedule_reconnect!
      max = config.ws_reconnect_max
      return if @reconnect_attempts >= max

      @reconnect_attempts += 1
      delay = config.ws_reconnect_base_delay * (2**(@reconnect_attempts - 1))
      delay = [ delay, 60 ].min # Cap at 60 seconds

      Rails.logger.info("[CollavreOpenclaw::WS] Reconnecting in #{delay}s (attempt #{@reconnect_attempts}/#{max})")

      EM.add_timer(delay) do
        next if @state == :disconnected # User explicitly disconnected

        begin
          queue = Queue.new
          do_connect!(queue)

          # Handshake result is handled by handle_response which sets @state.
          # Add a timeout to retry if handshake doesn't complete.
          EM.add_timer(config.ws_connect_timeout) do
            unless @handshake_done
              @handshake_done = true
              Rails.logger.warn("[CollavreOpenclaw::WS] Reconnect handshake timed out")
              @ws&.close
              schedule_reconnect!
            end
          end
        rescue => e
          Rails.logger.error("[CollavreOpenclaw::WS] Reconnect failed: #{e.message}")
          schedule_reconnect!
        end
      end
    end

    def extract_event_text(event)
      message = event[:message]
      return nil unless message.is_a?(Hash)

      content = message[:content]
      case content
      when String
        content
      when Array
        content.filter_map { |c| c[:text] if c[:type] == "text" }.join
      else
        nil
      end
    end

    def extract_agent_id
      return nil unless @user&.email.present?
      @user.email.split("@").first
    end

    def wait_with_timeout(queue, timeout_seconds, operation)
      # Use Queue#pop(timeout:) instead of Timeout.timeout to avoid Thread.raise corruption
      result = queue.pop(timeout: timeout_seconds)
      if result.nil? && queue.empty?
        raise TimeoutError, "#{operation} timed out after #{timeout_seconds}s"
      end
      result
    end
  end
end
