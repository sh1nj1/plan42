require "digest"
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
    COMPLETED_RUN_COOLDOWN = 5  # seconds to suppress late-arriving events for completed runs
    SEEN_EVENT_TTL = 30         # seconds to remember (runId, seq) pairs for dedup

    # WebSocket close codes → reconnection policy
    # :reconnect — schedule reconnect with exponential backoff
    # :fatal     — permanent failure (auth, forbidden), don't retry, propagate error
    # :normal    — clean shutdown, no reconnect, no error
    CLOSE_POLICIES = {
      1000 => :normal,      # Normal closure
      1001 => :reconnect,   # Going away (server shutting down)
      1006 => :reconnect,   # Abnormal closure (network issue)
      1008 => :fatal,       # Policy violation (likely auth)
      1011 => :reconnect,   # Internal server error
      4001 => :fatal,       # Auth failure (OpenClaw)
      4003 => :fatal       # Forbidden (OpenClaw)
    }.freeze

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
      @completed_runs = {}    # runId → monotonic timestamp (cooldown for late events)
      @seen_chat_events = {}  # "runId:seq" → monotonic timestamp (broadcast+nodeSend dedup)
      @proactive_handler = nil
      @reconnect_attempts = 0
      @last_activity_at = nil
      @tick_interval_ms = 15_000
      @tick_timer = nil
      @rpc_run_registrations = {} # RPC request_id → run_queue (for EM-thread runId registration)
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

      begin
        result = wait_with_timeout(queue, config.ws_connect_timeout, "connect")
      rescue TimeoutError, StandardError => e
        # Timeout or unexpected error — reset state and wake all waiters
        error_result = { error: e.message }
        @connect_mutex.synchronize do
          @state = :disconnected
          @connect_waiters.each { |q| q.push(error_result) }
          @connect_waiters.clear
        end
        raise ConnectionError, e.message
      end

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
      @rpc_run_registrations.clear
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

      # Send the RPC request to get the real runId.
      # IMPORTANT: We pass the run_queue via @rpc_run_registrations so that
      # handle_response can register @pending_runs[actual_run_id] on the EM
      # thread BEFORE any subsequent chat events arrive. This prevents a race
      # condition where fast Gateway responses send events before the Rails
      # thread can re-register with the actual runId.
      rpc_request_id = SecureRandom.uuid
      @mutex.synchronize { @rpc_run_registrations[rpc_request_id] = run_queue }

      response = send_rpc("chat.send", {
        sessionKey: session_key,
        message: message,
        idempotencyKey: idempotency_key
      }, request_id: rpc_request_id)

      # The EM thread already registered @pending_runs[actual_run_id] in
      # handle_response. Clean up the idempotency_key entry if a different
      # runId was assigned.
      actual_run_id = response&.dig(:runId) || idempotency_key
      if actual_run_id != idempotency_key
        @mutex.synchronize do
          @pending_runs.delete(idempotency_key)
          # Ensure runId is registered (may already be from handle_response)
          @pending_runs[actual_run_id] ||= run_queue
        end
      end

      # Stream events until final/error/aborted
      last_seq = nil

      loop do
        event = wait_with_timeout(run_queue, config.read_timeout, "chat response")

        break if event[:done]

        if event[:error]
          raise ChatError, event[:error]
        end

        # Gateway may broadcast + nodeSend the same event, causing
        # duplicates on the same WebSocket. Skip already-seen seqs for
        # deltas only. Terminal events (final, error, aborted) must NEVER
        # be skipped — they break the loop and unblock the caller.
        seq = event[:seq]
        event_state = event[:state]
        is_terminal = event_state == "final" || event_state == "error" || event_state == "aborted"

        if !is_terminal && seq && last_seq && seq <= last_seq
          next
        end
        last_seq = seq if seq

        case event_state
        when "delta"
          text = extract_event_text(event)
          if text.present?
            # Gateway sends accumulated content (full text so far) in
            # each delta event.  Compute the incremental delta for callers.
            delta = if response_text.present? && text.start_with?(response_text)
                      text[response_text.length..]
            else
                      text
            end
            response_text.replace(text)
            yield({ state: "delta", text: delta }) if delta.present? && block_given?
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

        # Record completed runs so late-arriving events are suppressed
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @completed_runs[actual_run_id] = now if actual_run_id
        @completed_runs[idempotency_key] = now if idempotency_key && idempotency_key != actual_run_id
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

    # Register a handler for proactive messages (unsolicited chat events).
    # The handler receives (user, payload) where user is the connection owner.
    def on_proactive_message(&handler)
      @proactive_handler = handler
    end

    # Register a callback invoked when the connection dies with a fatal close code
    # (auth failure, forbidden, etc.). ConnectionManager uses this to remove dead clients.
    def on_fatal_close(&handler)
      @on_fatal_close = handler
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

    # Determine reconnection policy for a WebSocket close code.
    # Returns :reconnect, :fatal, or :normal.
    def close_policy(code)
      CLOSE_POLICIES[code] || (code.to_i >= 4000 ? :fatal : :reconnect)
    end

    # Drain all pending requests and streaming runs with an error message.
    # Called on fatal close to unblock waiting Rails threads.
    def drain_pending_with_error!(message)
      @mutex.synchronize do
        @pending_requests.each_value { |pr| pr[:queue]&.push({ error: message }) }
        @pending_requests.clear
        @pending_runs.each_value { |q| q.push({ error: message }) }
        @pending_runs.clear
      end
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
        Rails.logger.info("[CollavreOpenclaw::WS] CONNECT gateway=#{url} state=open")
      end

      @ws.on :message do |event|
        handle_raw_message(event.data)
      end

      @ws.on :close do |event|
        code = event.code
        reason = event.reason
        policy = close_policy(code)
        Rails.logger.info("[CollavreOpenclaw::WS] DISCONNECT gateway=#{url} code=#{code} reason=#{reason} policy=#{policy}")

        cancel_tick_timer!

        unless @handshake_done
          @handshake_done = true
          @handshake_queue&.push({ error: "Connection closed during handshake (code=#{code})" })
        end

        case policy
        when :reconnect
          if @state == :connected || @state == :connecting
            @state = :reconnecting
            schedule_reconnect!
          end
        when :fatal
          @state = :disconnected
          drain_pending_with_error!("Connection closed with fatal code #{code}: #{reason}")
          @on_fatal_close&.call(self)
        when :normal
          @state = :disconnected
        end
      end
    end

    def handle_raw_message(data)
      touch_activity! # Refresh idle timer on any inbound traffic
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
      # Use valid client constants from OpenClaw protocol schema.
      # "gateway-client" and "backend" are appropriate for server-side integrations.
      # Do NOT include partial `device` — it requires full attestation (publicKey, signature, signedAt).

      params = {
        minProtocol: PROTOCOL_VERSION,
        maxProtocol: PROTOCOL_VERSION,
        client: {
          id: "gateway-client",
          version: CollavreOpenclaw::VERSION,
          platform: "ruby",
          mode: "backend"
        },
        role: "operator",
        scopes: [ "operator.read", "operator.write" ],
        caps: [],
        commands: [],
        permissions: {},
        auth: { token: @user.llm_api_key },
        locale: "en-US",
        userAgent: "collavre-openclaw/#{CollavreOpenclaw::VERSION}"
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
        # If this RPC response contains a runId (chat.send response), register
        # the run_queue under that runId NOW, on the EM thread, before any
        # subsequent chat events arrive. This eliminates the race condition
        # where fast events arrive before the Rails thread can re-register.
        if ok && payload.is_a?(Hash) && payload[:runId]
          run_queue = @mutex.synchronize { @rpc_run_registrations.delete(id) }
          if run_queue
            @mutex.synchronize { @pending_runs[payload[:runId]] = run_queue }
          end
        else
          @mutex.synchronize { @rpc_run_registrations.delete(id) }
        end

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
      seq = payload[:seq]

      # Dedup: Gateway sends identical events via broadcast() + nodeSendToSession().
      # Key includes state so that a delta and final with the same seq are NOT
      # treated as duplicates (they are different events that share a seq number).
      state = payload[:state]
      if run_id && seq && duplicate_chat_event?(run_id, seq, state)
        Rails.logger.debug("[CollavreOpenclaw::WS] CHAT run=#{run_id} seq=#{seq} state=dedup_skipped")
        return
      end

      # Check if this is a response to a pending chat.send
      run_queue = @mutex.synchronize { @pending_runs[run_id] }

      if run_queue
        # Known run — forward to the waiting thread
        run_queue.push(payload)
      elsif recently_completed_run?(run_id)
        # Late-arriving event for a run we already finished — suppress it
        Rails.logger.info("[CollavreOpenclaw::WS] CHAT run=#{run_id} state=late_suppressed")
      elsif @proactive_handler
        # Unknown run — proactive message from Gateway (cron/heartbeat)
        Rails.logger.info("[CollavreOpenclaw::WS] CHAT run=#{run_id} state=proactive")
        @proactive_handler.call(@user, payload)
      else
        Rails.logger.debug("[CollavreOpenclaw::WS] CHAT run=#{run_id} state=ignored_no_handler")
      end
    end

    # Check if this (runId, seq, state) triple was already seen. Records it if new.
    # Gateway emits each event via broadcast() AND nodeSendToSession(),
    # delivering the identical payload twice. Including state in the key
    # ensures a delta and final with the same seq are treated as distinct events.
    def duplicate_chat_event?(run_id, seq, state = nil)
      key = "#{run_id}:#{seq}:#{state}"
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @mutex.synchronize do
        # Sweep expired entries periodically
        if @seen_chat_events.size > 100
          @seen_chat_events.delete_if { |_k, ts| now - ts > SEEN_EVENT_TTL }
        end

        if @seen_chat_events.key?(key)
          true
        else
          @seen_chat_events[key] = now
          false
        end
      end
    end

    # Check if a runId was recently completed (within cooldown window).
    # Also sweeps expired entries to prevent unbounded growth.
    def recently_completed_run?(run_id)
      @mutex.synchronize do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        # Sweep expired entries
        @completed_runs.delete_if { |_id, ts| now - ts > COMPLETED_RUN_COOLDOWN }

        @completed_runs.key?(run_id)
      end
    end

    def handle_tick(_payload)
      # The tick event from Gateway is a keepalive heartbeat.
      # Receiving it already refreshes our activity timer (via touch_activity!
      # in handle_raw_message). No response is needed.
    end

    def start_tick_timer!
      # No-op. The Gateway sends tick events to keep the connection alive.
      # We don't need to send proactive keepalives; receiving the Gateway's
      # ticks is sufficient. (The "poll" RPC method is NOT a keepalive — it
      # requires user-facing params like to/question/options/idempotencyKey.)
    end

    def cancel_tick_timer!
      @tick_timer&.cancel
      @tick_timer = nil
    end

    # Send an RPC request and block until the response.
    # Returns the response payload.
    #
    # @param method [String] RPC method name
    # @param params [Hash] RPC parameters
    # @param request_id [String, nil] Pre-generated request ID. Used by chat_send
    #   to correlate the RPC response with the run_queue for EM-thread runId
    #   registration (see handle_response). If nil, a random UUID is generated.
    def send_rpc(method, params, request_id: nil)
      request_id ||= SecureRandom.uuid
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

      url = gateway_ws_url
      Rails.logger.info("[CollavreOpenclaw::WS] RECONNECT gateway=#{url} attempt=#{@reconnect_attempts}/#{max} delay=#{delay}s")

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
              Rails.logger.warn("[CollavreOpenclaw::WS] RECONNECT gateway=#{url} state=handshake_timeout")
              @ws&.close
              schedule_reconnect!
            end
          end
        rescue => e
          Rails.logger.error("[CollavreOpenclaw::WS] RECONNECT gateway=#{url} state=fail reason=#{e.message}")
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
