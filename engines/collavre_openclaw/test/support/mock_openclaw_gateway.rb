require "em-websocket"
require "json"
require "securerandom"

module CollavreOpenclaw
  # Minimal mock OpenClaw Gateway for integration tests.
  #
  # Runs inside the shared EmReactor (same EM.run loop). Uses programmable
  # response scripts so each test defines expected behavior.
  #
  # Usage:
  #   gateway = MockOpenclawGateway.new(port: 0) # random port
  #   gateway.script = [
  #     { on: "connect", respond: :hello_ok },
  #     { on: "chat.send", respond: :stream_deltas, text: "Hello world" },
  #   ]
  #   gateway.start!
  #   # ... run tests against ws://localhost:#{gateway.port}/ ...
  #   gateway.stop!
  class MockOpenclawGateway
    attr_reader :port
    attr_accessor :script

    PROTOCOL_VERSION = 3

    def initialize(port: 0)
      @requested_port = port
      @port = nil
      @script = []
      @script_index = 0
      @server_signature = nil
      @connections = []
      @started = false
      @mutex = Mutex.new
    end

    def start!
      return if @started

      ready = Queue.new

      EmReactor.next_tick do
        begin
          # Use port 0 to let OS assign a free port, then read it back
          use_port = @requested_port == 0 ? find_free_port : @requested_port

          @server_signature = EM::WebSocket.start(host: "127.0.0.1", port: use_port) do |ws|
            setup_connection(ws)
          end

          @port = use_port
          @started = true
          ready.push({ ok: true, port: use_port })
        rescue StandardError => e
          ready.push({ error: e.message })
        end
      end

      result = ready.pop
      raise "MockOpenclawGateway failed to start: #{result[:error]}" if result[:error]
    end

    def stop!
      return unless @started

      done = Queue.new

      EmReactor.next_tick do
        begin
          @connections.each { |ws| ws.close rescue nil }
          @connections.clear

          if @server_signature
            EM.stop_server(@server_signature)
            @server_signature = nil
          end
        rescue StandardError => e
          # Ignore cleanup errors
        ensure
          @started = false
          @port = nil
          @script_index = 0
          done.push(true)
        end
      end

      done.pop
    end

    def url
      "ws://127.0.0.1:#{@port}/"
    end

    # Reset script index for reuse between sub-tests
    def reset!
      @script_index = 0
    end

    private

    def find_free_port
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      port
    end

    def setup_connection(ws)
      @connections << ws

      ws.onopen do
        # Send connect.challenge event
        send_event(ws, "connect.challenge", {
          nonce: SecureRandom.hex(16)
        })
      end

      ws.onmessage do |msg|
        handle_message(ws, msg)
      end

      ws.onclose do
        @connections.delete(ws)
      end
    end

    def handle_message(ws, raw)
      frame = JSON.parse(raw, symbolize_names: true)

      case frame[:type]
      when "req"
        handle_request(ws, frame)
      end
    rescue JSON::ParserError
      # Ignore malformed messages
    end

    def handle_request(ws, frame)
      method = frame[:method]
      id = frame[:id]
      params = frame[:params] || {}

      case method
      when "connect"
        handle_connect(ws, id, params)
      when "chat.send"
        handle_chat_send(ws, id, params)
      when "chat.history"
        handle_chat_history(ws, id, params)
      when "chat.abort"
        handle_chat_abort(ws, id, params)
      when "poll"
        # Tick acknowledgment — no response needed
      else
        send_response(ws, id, false, nil, { message: "Unknown method: #{method}" })
      end
    end

    def handle_connect(ws, id, params)
      step = current_script_step("connect")

      case step&.dig(:respond)
      when :hello_ok, nil
        # Default: successful handshake
        send_response(ws, id, true, {
          protocol: PROTOCOL_VERSION,
          policy: {
            tickIntervalMs: 30_000
          }
        })
      when :auth_failure
        code = step[:code] || 4001
        send_response(ws, id, false, nil, { message: "Authentication failed" })
        EM.next_tick { ws.close(code, "Authentication failed") }
      end
    end

    def handle_chat_send(ws, id, params)
      step = current_script_step("chat.send")
      session_key = params[:sessionKey]
      # By default, use idempotencyKey as runId. Scripts can set
      # own_run_id: true to generate a different runId (simulating
      # real Gateway behavior where runId != idempotencyKey).
      run_id = if step&.dig(:own_run_id)
                 SecureRandom.uuid
      else
                 params[:idempotencyKey] || SecureRandom.uuid
      end

      case step&.dig(:respond)
      when :stream_deltas, nil
        text = step&.dig(:text) || "Hello from mock gateway"

        # Send RPC response with runId
        send_response(ws, id, true, { runId: run_id })

        # Stream all words as deltas (accumulated), then send a final event
        words = text.split(" ")
        accumulated = +""
        seq = 0

        words.each do |word|
          accumulated << " " unless accumulated.empty?
          accumulated << word

          send_event(ws, "chat", {
            runId: run_id,
            sessionKey: session_key,
            seq: seq,
            state: "delta",
            message: { role: "assistant", content: accumulated.dup }
          })
          seq += 1
        end

        # Final event with full text
        send_event(ws, "chat", {
          runId: run_id,
          sessionKey: session_key,
          seq: seq,
          state: "final",
          message: { role: "assistant", content: text }
        })

      when :error
        error_msg = step[:error_message] || "Something went wrong"
        send_response(ws, id, true, { runId: run_id })
        send_event(ws, "chat", {
          runId: run_id,
          sessionKey: session_key,
          seq: 0,
          state: "error",
          errorMessage: error_msg,
          message: { role: "assistant", content: "" }
        })

      when :drop_connection
        send_response(ws, id, true, { runId: run_id })
        # Send one delta then drop
        send_event(ws, "chat", {
          runId: run_id,
          sessionKey: session_key,
          seq: 0,
          state: "delta",
          message: { role: "assistant", content: "partial" }
        })
        EM.next_tick { ws.close(1006, "Simulated connection drop") }

      when :duplicate_events
        text = step[:text] || "Hello"
        send_response(ws, id, true, { runId: run_id })

        # Send delta twice (simulating broadcast + nodeSend)
        delta_event = {
          runId: run_id, sessionKey: session_key, seq: 0,
          state: "delta", message: { role: "assistant", content: text }
        }
        send_event(ws, "chat", delta_event)
        send_event(ws, "chat", delta_event)

        # Send final twice
        final_event = {
          runId: run_id, sessionKey: session_key, seq: 1,
          state: "final", message: { role: "assistant", content: text }
        }
        send_event(ws, "chat", final_event)
        send_event(ws, "chat", final_event)
      end
    end

    def handle_chat_history(ws, id, params)
      send_response(ws, id, true, {
        messages: [],
        sessionKey: params[:sessionKey]
      })
    end

    def handle_chat_abort(ws, id, params)
      send_response(ws, id, true, { aborted: true })
    end

    # Send a proactive message to all connected clients.
    # Call this from tests to simulate Gateway-initiated messages.
    public def send_proactive_message(session_key:, text:)
      run_id = SecureRandom.uuid
      @connections.each do |ws|
        send_event(ws, "chat", {
          runId: run_id,
          sessionKey: session_key,
          seq: 0,
          state: "final",
          message: { role: "assistant", content: text }
        })
      end
    end

    private

    def current_script_step(method_name)
      @mutex.synchronize do
        step = @script[@script_index]
        if step && step[:on] == method_name
          @script_index += 1
          step
        else
          nil
        end
      end
    end

    def send_response(ws, id, ok, payload, error = nil)
      frame = { type: "res", id: id, ok: ok }
      frame[:payload] = payload if payload
      frame[:error] = error if error
      ws.send(JSON.generate(frame))
    end

    def send_event(ws, event_name, payload)
      frame = {
        type: "event",
        event: event_name,
        payload: payload
      }
      ws.send(JSON.generate(frame))
    end
  end
end
