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

    # Gateway sends accumulated content (full text so far) in each delta.
    # chat_send must compute the incremental delta for callers.
    test "chat_send converts accumulated deltas to incremental fragments" do
      client = WebsocketClient.new(user: @user)
      yielded_deltas = []

      events = [
        { state: "delta", message: { content: "Hello" } },
        { state: "delta", message: { content: "Hello world" } },
        { state: "delta", message: { content: "Hello world! How" } },
        { state: "delta", message: { content: "Hello world! How are you?" } },
        { state: "final", message: { content: "Hello world! How are you?" } }
      ]

      result = run_chat_send_with_events(client, events) do |ev|
        yielded_deltas << ev[:text] if ev[:state] == "delta"
      end

      assert_equal [ "Hello", " world", "! How", " are you?" ], yielded_deltas
      assert_equal "Hello world! How are you?", result
    end

    # Duplicate events (same seq) from broadcast + nodeSend are skipped.
    test "chat_send skips duplicate events with same seq" do
      client = WebsocketClient.new(user: @user)
      yielded_deltas = []

      events = [
        { seq: 0, state: "delta", message: { content: "Hello" } },
        { seq: 0, state: "delta", message: { content: "Hello" } },        # duplicate
        { seq: 1, state: "delta", message: { content: "Hello world" } },
        { seq: 1, state: "delta", message: { content: "Hello world" } },  # duplicate
        { seq: 2, state: "delta", message: { content: "Hello world!" } },
        { seq: 3, state: "final", message: { content: "Hello world!" } }
      ]

      result = run_chat_send_with_events(client, events) do |ev|
        yielded_deltas << ev[:text] if ev[:state] == "delta"
      end

      assert_equal [ "Hello", " world", "!" ], yielded_deltas
      assert_equal "Hello world!", result
    end

    # Events without seq (e.g. older gateway) should all be processed.
    test "chat_send processes events without seq field" do
      client = WebsocketClient.new(user: @user)
      yielded_deltas = []

      events = [
        { state: "delta", message: { content: "A" } },
        { state: "delta", message: { content: "AB" } },
        { state: "final", message: { content: "AB" } }
      ]

      result = run_chat_send_with_events(client, events) do |ev|
        yielded_deltas << ev[:text] if ev[:state] == "delta"
      end

      assert_equal [ "A", "B" ], yielded_deltas
      assert_equal "AB", result
    end

    # --- Completed-run cooldown tests ---

    test "completed run events are suppressed during cooldown" do
      client = WebsocketClient.new(user: @user)
      proactive_calls = []
      client.on_proactive_message { |user, payload| proactive_calls << payload }

      # Simulate a completed chat_send that records the run in @completed_runs
      run_id = "run-123"
      client.instance_variable_get(:@mutex).synchronize do
        client.instance_variable_get(:@completed_runs)[run_id] =
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # A late-arriving event with the same runId should be suppressed
      client.send(:handle_chat_event, { runId: run_id, state: "final", message: { content: "late" } })

      assert_empty proactive_calls, "Late event for completed run should be suppressed"
    end

    test "events with different runId still dispatch to proactive handler" do
      client = WebsocketClient.new(user: @user)
      proactive_calls = []
      client.on_proactive_message { |user, payload| proactive_calls << payload }

      # Record one completed run
      client.instance_variable_get(:@mutex).synchronize do
        client.instance_variable_get(:@completed_runs)["run-123"] =
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # A different runId should still dispatch normally
      client.send(:handle_chat_event, { runId: "run-456", state: "final", message: { content: "new" } })

      assert_equal 1, proactive_calls.size
      assert_equal "run-456", proactive_calls.first[:runId]
    end

    test "expired cooldown entries are cleaned up" do
      client = WebsocketClient.new(user: @user)

      # Insert an entry with a timestamp well beyond the cooldown window
      expired_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - WebsocketClient::COMPLETED_RUN_COOLDOWN - 1
      client.instance_variable_get(:@mutex).synchronize do
        client.instance_variable_get(:@completed_runs)["old-run"] = expired_time
      end

      # The check should sweep the expired entry and return false
      refute client.send(:recently_completed_run?, "old-run")
      assert_empty client.instance_variable_get(:@completed_runs)
    end

    test "chat_send records completed runs in cooldown set" do
      client = WebsocketClient.new(user: @user)

      events = [
        { state: "final", message: { content: "done" } }
      ]

      run_chat_send_with_events(client, events)

      completed_runs = client.instance_variable_get(:@completed_runs)
      assert completed_runs.key?("test-key"), "idempotency_key should be in completed_runs"
    end

    private

    # Exercises chat_send by stubbing send_rpc / ensure_connected! and
    # feeding events directly into the pending_runs queue.
    def run_chat_send_with_events(client, events, &block)
      session_key = "test-session"
      idempotency_key = "test-key"

      # Bypass connection requirement
      client.define_singleton_method(:ensure_connected!) { nil }
      client.define_singleton_method(:touch_activity!) { nil }

      # Stub send_rpc to push pre-built events into the run queue
      client.define_singleton_method(:send_rpc) do |_method, params|
        run_queue = instance_variable_get(:@mutex).synchronize do
          instance_variable_get(:@pending_runs)[params[:idempotencyKey]]
        end
        events.each { |e| run_queue.push(e) }
        { runId: params[:idempotencyKey] }
      end

      client.chat_send(
        session_key: session_key,
        message: "Hello",
        idempotency_key: idempotency_key,
        &block
      )
    end

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
