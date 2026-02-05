require "test_helper"

module CollavreOpenclaw
  class ProactiveMessageHandlerTest < ActiveSupport::TestCase
    setup do
      @handler = ProactiveMessageHandler.new
      @user = User.create!(
        email: "proactive-test@example.com",
        password: "password123",
        name: "Test Bot",
        gateway_url: "https://test-gateway.com"
      )
    end

    teardown do
      @user&.destroy
    end

    # ─────────────────────────────────────────────
    # Session key parsing
    # ─────────────────────────────────────────────

    test "parse_session_key extracts all components" do
      key = "agent:ai-bot:collavre:42:creative:100:topic:200"
      result = ProactiveMessageHandler.parse_session_key(key)

      assert_equal "ai-bot", result[:agent_id]
      assert_equal 42, result[:user_id]
      assert_equal 100, result[:creative_id]
      assert_equal 200, result[:topic_id]
    end

    test "parse_session_key handles missing topic" do
      key = "agent:main:collavre:1:creative:55"
      result = ProactiveMessageHandler.parse_session_key(key)

      assert_equal "main", result[:agent_id]
      assert_equal 1, result[:user_id]
      assert_equal 55, result[:creative_id]
      assert_nil result[:topic_id]
    end

    test "parse_session_key handles missing creative and topic" do
      key = "agent:bot:collavre:7"
      result = ProactiveMessageHandler.parse_session_key(key)

      assert_equal "bot", result[:agent_id]
      assert_equal 7, result[:user_id]
      assert_nil result[:creative_id]
      assert_nil result[:topic_id]
    end

    test "parse_session_key returns empty hash for nil" do
      assert_equal({}, ProactiveMessageHandler.parse_session_key(nil))
    end

    test "parse_session_key returns empty hash for blank string" do
      assert_equal({}, ProactiveMessageHandler.parse_session_key(""))
    end

    # ─────────────────────────────────────────────
    # Delta buffering
    # ─────────────────────────────────────────────

    test "buffers delta events by runId" do
      payload1 = {
        runId: "run-1",
        sessionKey: "agent:bot:collavre:1:creative:100:topic:200",
        state: "delta",
        message: { content: "Hello " }
      }
      payload2 = {
        runId: "run-1",
        sessionKey: "agent:bot:collavre:1:creative:100:topic:200",
        state: "delta",
        message: { content: "world" }
      }

      @handler.handle(@user, payload1)
      @handler.handle(@user, payload2)

      buffer = @handler.instance_variable_get(:@buffers)["run-1"]
      assert_equal "Hello world", buffer[:text]
    end

    # ─────────────────────────────────────────────
    # Final event → Job dispatch
    # ─────────────────────────────────────────────

    test "dispatches job on final event with buffered deltas" do
      dispatched = capture_job_dispatch do
        # Buffer deltas
        @handler.handle(@user, {
          runId: "run-2",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:100:topic:200",
          state: "delta",
          message: { content: "Proactive " }
        })
        @handler.handle(@user, {
          runId: "run-2",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:100:topic:200",
          state: "delta",
          message: { content: "message" }
        })
        # Final event
        @handler.handle(@user, {
          runId: "run-2",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:100:topic:200",
          state: "final",
          message: { content: "Proactive message" }
        })
      end

      assert_equal 1, dispatched.size
      assert_equal @user.id, dispatched.first[:user_id]
      assert_equal "proactive", dispatched.first[:payload]["type"]
      assert_equal "Proactive message", dispatched.first[:payload]["content"]

      # Buffer should be cleaned up
      assert_nil @handler.instance_variable_get(:@buffers)["run-2"]
    end

    test "dispatches job on final-only event (no deltas)" do
      dispatched = capture_job_dispatch do
        @handler.handle(@user, {
          runId: "run-3",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
          state: "final",
          message: { content: "Direct final message" }
        })
      end

      assert_equal 1, dispatched.size
      assert_equal "Direct final message", dispatched.first[:payload]["content"]
    end

    test "does not dispatch job without creative_id in session key" do
      dispatched = capture_job_dispatch do
        @handler.handle(@user, {
          runId: "run-4",
          sessionKey: "agent:bot:collavre:#{@user.id}",
          state: "final",
          message: { content: "No creative context" }
        })
      end

      assert_empty dispatched
    end

    test "does not dispatch job with empty content" do
      dispatched = capture_job_dispatch do
        @handler.handle(@user, {
          runId: "run-5",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
          state: "final",
          message: { content: "" }
        })
      end

      assert_empty dispatched
    end

    # ─────────────────────────────────────────────
    # Error handling
    # ─────────────────────────────────────────────

    test "cleans up buffer on error event" do
      @handler.handle(@user, {
        runId: "run-err",
        sessionKey: "agent:bot:collavre:1:creative:100",
        state: "delta",
        message: { content: "partial" }
      })

      @handler.handle(@user, {
        runId: "run-err",
        state: "error",
        errorMessage: "Something went wrong"
      })

      assert_nil @handler.instance_variable_get(:@buffers)["run-err"]
    end

    test "cleans up buffer on aborted event" do
      @handler.handle(@user, {
        runId: "run-abort",
        sessionKey: "agent:bot:collavre:1:creative:100",
        state: "delta",
        message: { content: "partial" }
      })

      @handler.handle(@user, {
        runId: "run-abort",
        state: "aborted"
      })

      assert_nil @handler.instance_variable_get(:@buffers)["run-abort"]
    end

    # ─────────────────────────────────────────────
    # Array content format
    # ─────────────────────────────────────────────

    test "handles array content format" do
      dispatched = capture_job_dispatch do
        @handler.handle(@user, {
          runId: "run-arr",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
          state: "final",
          message: {
            content: [
              { type: "text", text: "Part 1 " },
              { type: "text", text: "Part 2" }
            ]
          }
        })
      end

      assert_equal 1, dispatched.size
      assert_equal "Part 1 Part 2", dispatched.first[:payload]["content"]
    end

    test "ignores events without runId" do
      # Should not raise
      @handler.handle(@user, { state: "delta", message: { content: "orphan" } })
      assert_empty @handler.instance_variable_get(:@buffers)
    end

    # ─────────────────────────────────────────────
    # Job payload verification
    # ─────────────────────────────────────────────

    test "dispatched job includes correct payload structure" do
      dispatched = capture_job_dispatch do
        @handler.handle(@user, {
          runId: "run-verify",
          sessionKey: "agent:bot:collavre:#{@user.id}:creative:42:topic:99",
          state: "final",
          message: { content: "Test message" }
        })
      end

      assert_equal 1, dispatched.size
      job = dispatched.first

      assert_equal @user.id, job[:user_id]
      payload = job[:payload]
      assert_equal "proactive", payload["type"]
      assert_equal "Test message", payload["content"]
      assert_equal 42, payload["creative_id"]
      assert_equal 42, payload.dig("context", "creative_id")
      assert_equal 99, payload.dig("context", "thread_id")
    end

    # ─────────────────────────────────────────────
    # Multiple concurrent runs
    # ─────────────────────────────────────────────

    test "handles multiple concurrent proactive runs independently" do
      dispatched = capture_job_dispatch do
        # Interleave deltas from two different runs
        @handler.handle(@user, {
          runId: "run-a", sessionKey: "agent:bot:collavre:#{@user.id}:creative:10",
          state: "delta", message: { content: "Run A " }
        })
        @handler.handle(@user, {
          runId: "run-b", sessionKey: "agent:bot:collavre:#{@user.id}:creative:20",
          state: "delta", message: { content: "Run B " }
        })
        @handler.handle(@user, {
          runId: "run-a", sessionKey: "agent:bot:collavre:#{@user.id}:creative:10",
          state: "delta", message: { content: "complete" }
        })
        @handler.handle(@user, {
          runId: "run-b", sessionKey: "agent:bot:collavre:#{@user.id}:creative:20",
          state: "delta", message: { content: "complete" }
        })
        # Final events (text may be empty or full; buffered deltas are used)
        @handler.handle(@user, {
          runId: "run-a", sessionKey: "agent:bot:collavre:#{@user.id}:creative:10",
          state: "final", message: { content: "" }
        })
        @handler.handle(@user, {
          runId: "run-b", sessionKey: "agent:bot:collavre:#{@user.id}:creative:20",
          state: "final", message: { content: "" }
        })
      end

      assert_equal 2, dispatched.size
      contents = dispatched.map { |j| j[:payload]["content"] }.sort
      assert_includes contents, "Run A complete"
      assert_includes contents, "Run B complete"

      # Both buffers should be cleaned up
      assert_empty @handler.instance_variable_get(:@buffers)
    end

    # ─────────────────────────────────────────────
    # Stale buffer TTL cleanup
    # ─────────────────────────────────────────────

    test "purges stale buffers older than BUFFER_TTL" do
      # Create a buffer with an old timestamp
      @handler.handle(@user, {
        runId: "run-stale",
        sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
        state: "delta",
        message: { content: "old data" }
      })

      buffers = @handler.instance_variable_get(:@buffers)
      assert buffers.key?("run-stale")

      # Simulate aging: set created_at to past BUFFER_TTL
      buffers["run-stale"][:created_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                                          ProactiveMessageHandler::BUFFER_TTL - 1

      # Force sweep by setting last_sweep_at far in the past
      @handler.instance_variable_set(:@last_sweep_at,
                                     Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                                     ProactiveMessageHandler::SWEEP_INTERVAL - 1)

      # Trigger sweep via a new event
      @handler.handle(@user, {
        runId: "run-trigger",
        sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
        state: "delta",
        message: { content: "new data" }
      })

      # Stale buffer should be purged, new one should remain
      assert_nil buffers["run-stale"], "Stale buffer should be purged"
      assert buffers.key?("run-trigger"), "Fresh buffer should remain"
    end

    test "does not purge buffers within BUFFER_TTL" do
      @handler.handle(@user, {
        runId: "run-fresh",
        sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
        state: "delta",
        message: { content: "fresh data" }
      })

      # Force sweep timing
      @handler.instance_variable_set(:@last_sweep_at,
                                     Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                                     ProactiveMessageHandler::SWEEP_INTERVAL - 1)

      # Trigger sweep
      @handler.handle(@user, {
        runId: "run-trigger2",
        sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
        state: "delta",
        message: { content: "trigger" }
      })

      buffers = @handler.instance_variable_get(:@buffers)
      assert buffers.key?("run-fresh"), "Fresh buffer should not be purged"
      assert buffers.key?("run-trigger2")
    end

    test "sweep does not run more often than SWEEP_INTERVAL" do
      @handler.handle(@user, {
        runId: "run-old",
        sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
        state: "delta",
        message: { content: "data" }
      })

      buffers = @handler.instance_variable_get(:@buffers)
      # Make buffer stale
      buffers["run-old"][:created_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                                        ProactiveMessageHandler::BUFFER_TTL - 1

      # But last_sweep_at is recent (default from initialization)
      # → sweep should NOT run
      @handler.handle(@user, {
        runId: "run-trigger3",
        sessionKey: "agent:bot:collavre:#{@user.id}:creative:100",
        state: "delta",
        message: { content: "trigger" }
      })

      # Stale buffer should still be there because sweep interval hasn't elapsed
      assert buffers.key?("run-old"), "Buffer should remain when sweep interval hasn't elapsed"
    end

    private

    # Capture dispatch_to_job calls by stubbing the handler's private method.
    # This avoids monkey-patching CallbackProcessorJob which can leak to other tests.
    # Preserves the creative_id guard from the real implementation.
    def capture_job_dispatch
      dispatched = []

      @handler.define_singleton_method(:dispatch_to_job) do |user, content, context|
        creative_id = context[:creative_id]
        return unless creative_id.present? # preserve original guard

        dispatched << {
          user_id: user.id,
          payload: {
            "type" => "proactive",
            "content" => content,
            "creative_id" => creative_id,
            "context" => {
              "creative_id" => creative_id,
              "thread_id" => context[:topic_id]
            }
          }
        }
      end

      yield

      dispatched
    end
  end
end
