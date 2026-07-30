require "test_helper"
require "minitest/mock"

module CollavreOpenclaw
  class OpenclawAdapterTest < ActiveSupport::TestCase
    def setup
      @user = Minitest::Mock.new
      @user.expect :id, 1
      @user.expect :gateway_url, "https://test-gateway.com"
    end

    test "initializes with user and system prompt" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "You are a helpful assistant",
        context: {}
      )

      assert_not_nil adapter
    end

    test "builds correct payload format on first message" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages_data = {
        messages: [
          { role: "user", kind: :creative_context, parts: [ { text: "Creative (id: 1):\n# Hello" } ] },
          { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] }
        ],
        first_message: true,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, messages_data)
      payload = adapter.send(:build_payload)

      # System prompt + context + trigger
      assert_equal 3, payload[:messages].length
      assert_equal "system", payload[:messages][0][:role]
      assert_equal "Test prompt", payload[:messages][0][:content]
      assert_equal "user", payload[:messages][1][:role]
      assert_includes payload[:messages][1][:content], "Creative (id: 1)"
      assert_equal "user", payload[:messages][2][:role]
      assert_equal "Hello", payload[:messages][2][:content]
      assert payload[:stream]
      assert_equal "openclaw:test", payload[:model]
    end

    test "builds payload with all received messages (pure transport)" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      # SessionContextResolver already filtered to trigger-only for warm sessions
      messages_data = {
        messages: [
          { role: "user", kind: :trigger, parts: [ { text: "Follow-up" } ] }
        ],
        first_message: false,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, messages_data)
      payload = adapter.send(:build_payload)

      # System prompt + trigger (adapter sends everything it receives)
      assert_equal 2, payload[:messages].length
      assert_equal "system", payload[:messages][0][:role]
      assert_equal "Test prompt", payload[:messages][0][:content]
      assert_equal "user", payload[:messages][1][:role]
      assert_equal "Follow-up", payload[:messages][1][:content]
    end

    test "builds payload without system prompt when nil" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      # SessionContextResolver sets system_prompt to nil for incremental sessions
      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: nil,
        context: {}
      )

      messages_data = {
        messages: [
          { role: "user", kind: :trigger, parts: [ { text: "Follow-up" } ] }
        ],
        first_message: false,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, messages_data)
      payload = adapter.send(:build_payload)

      # Trigger only — no system prompt
      assert_equal 1, payload[:messages].length
      assert_equal "user", payload[:messages][0][:role]
      assert_equal "Follow-up", payload[:messages][0][:content]
    end

    test "includes agent_id derived from user email in model field" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "ai-bot@collavre.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      adapter.send(:parse_messages_data!, { messages: [ { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] } ], first_message: true, context_changed: false })
      payload = adapter.send(:build_payload)

      assert_equal "openclaw:ai-bot", payload[:model]
    end

    test "uses plain openclaw model when user email is blank" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: nil)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      adapter.send(:parse_messages_data!, { messages: [ { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] } ], first_message: true, context_changed: false })
      payload = adapter.send(:build_payload)

      assert_equal "openclaw", payload[:model]
    end

    test "normalizes message roles correctly" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      assert_equal "user", adapter.send(:normalize_role, "user")
      assert_equal "assistant", adapter.send(:normalize_role, "model")
      assert_equal "assistant", adapter.send(:normalize_role, "assistant")
      assert_equal "system", adapter.send(:normalize_role, "system")
      assert_equal "user", adapter.send(:normalize_role, "unknown")
    end

    test "format_single_message adds sender attribution to user messages" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      msg = { role: "user", content: "Hello", sender_name: "Shinji" }
      formatted = adapter.send(:format_single_message, msg)
      assert_equal "[Shinji]: Hello", formatted[:content]

      msg2 = { role: "user", content: "Question", sender_name: "Jane" }
      formatted2 = adapter.send(:format_single_message, msg2)
      assert_equal "[Jane]: Question", formatted2[:content]
    end

    test "format_single_message does not add sender attribution to assistant messages" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      msg = { role: "assistant", content: "Response", sender_name: "AI Bot" }
      formatted = adapter.send(:format_single_message, msg)
      assert_equal "Response", formatted[:content]
    end

    test "format_single_message includes image as base64 data URL in OpenAI format" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("\x89PNG\r\n\x1a\n" + "\x00" * 100),
        filename: "test.png",
        content_type: "image/png"
      )

      msg = { role: "user", parts: [ { text: "What is this?" }, { image: blob } ] }
      formatted = adapter.send(:format_single_message, msg)

      assert_equal "user", formatted[:role]
      assert_instance_of Array, formatted[:content]
      assert_equal 2, formatted[:content].size

      text_part = formatted[:content].find { |p| p[:type] == "text" }
      image_part = formatted[:content].find { |p| p[:type] == "image_url" }

      assert_equal "What is this?", text_part[:text]
      assert image_part[:image_url][:url].start_with?("data:image/png;base64,")
    ensure
      blob&.purge
    end

    test "format_single_message keeps plain text when no images" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      msg = { role: "user", parts: [ { text: "Hello" } ] }
      formatted = adapter.send(:format_single_message, msg)

      assert_equal "user", formatted[:role]
      assert_equal "Hello", formatted[:content]
      assert_instance_of String, formatted[:content]
    end

    test "builds session key based on topic" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 123, topic_id: 456 }
      )

      session_key = adapter.session_key

      assert_includes session_key, "collavre"
      assert_includes session_key, "creative:123"
      assert_includes session_key, "topic:456"
    end

    test "session key starts with agent prefix for OpenClaw routing" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "ming@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 123 }
      )

      session_key = adapter.session_key

      # Session key must start with "agent:" for OpenClaw to route correctly
      assert session_key.start_with?("agent:"), "Session key must start with 'agent:' prefix"
      assert_includes session_key, "agent:ming:"
    end

    test "session key includes agent_id derived from email" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "ai-bot@collavre.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 100 }
      )

      session_key = adapter.session_key

      # Should be: agent:ai-bot:collavre:1:creative:100
      assert_match(/^agent:ai-bot:collavre:\d+:creative:100$/, session_key)
    end

    test "session key uses main agent when email is blank" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: nil)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 100 }
      )

      session_key = adapter.session_key

      # Should fallback to "main" agent
      assert session_key.start_with?("agent:main:"), "Should use 'main' agent when email is blank"
    end

    test "session key is stable for same topic" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter1 = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 100, topic_id: 200 }
      )

      adapter2 = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 100, topic_id: 200 }
      )

      assert_equal adapter1.session_key, adapter2.session_key
    end

    test "session key differs for different topics" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter1 = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 100, topic_id: 200 }
      )

      adapter2 = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 100, topic_id: 300 }
      )

      assert_not_equal adapter1.session_key, adapter2.session_key
    end

    test "session key infers topic_id from comment object in context" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "bot@example.com")

      # Simulate a comment object with topic_id (as passed by AiAgentService)
      comment = Object.new
      comment.define_singleton_method(:id) { 42 }
      comment.define_singleton_method(:topic_id) { 789 }

      creative = Object.new
      creative.define_singleton_method(:id) { 100 }

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative: creative, comment: comment }
      )

      session_key = adapter.session_key

      assert_includes session_key, "creative:100"
      assert_includes session_key, "topic:789"
    end

    test "session key does not include topic when comment has no topic_id" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "bot@example.com")

      comment = Object.new
      comment.define_singleton_method(:id) { 42 }
      comment.define_singleton_method(:topic_id) { nil }

      creative = Object.new
      creative.define_singleton_method(:id) { 100 }

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative: creative, comment: comment }
      )

      session_key = adapter.session_key

      assert_includes session_key, "creative:100"
      assert_not_includes session_key, "topic:"
    end

    test "explicit topic_id takes precedence over inferred from comment" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "bot@example.com")

      comment = Object.new
      comment.define_singleton_method(:id) { 42 }
      comment.define_singleton_method(:topic_id) { 789 }

      creative = Object.new
      creative.define_singleton_method(:id) { 100 }

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative: creative, comment: comment, topic_id: 555 }
      )

      session_key = adapter.session_key

      assert_includes session_key, "topic:555"
      assert_not_includes session_key, "topic:789"
    end

    test "session key differs for different agents" do
      user1 = build_test_user(gateway_url: "https://test-gateway.com", email: "agent-a@example.com")
      user2 = build_test_user(gateway_url: "https://test-gateway.com", email: "agent-b@example.com")

      adapter1 = OpenclawAdapter.new(
        user: user1,
        system_prompt: "",
        context: { creative_id: 100, topic_id: 200 }
      )

      adapter2 = OpenclawAdapter.new(
        user: user2,
        system_prompt: "",
        context: { creative_id: 100, topic_id: 200 }
      )

      # Different agents should have different session keys even for same creative/topic
      assert_not_equal adapter1.session_key, adapter2.session_key
      assert_includes adapter1.session_key, "agent:agent-a:"
      assert_includes adapter2.session_key, "agent:agent-b:"
    end

    test "builds authorization header with llm_api_key" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-api-key-123")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      headers = adapter.send(:build_headers)

      assert_equal "Bearer test-api-key-123", headers["Authorization"]
      assert_equal "application/json", headers["Content-Type"]
      assert_equal "text/event-stream", headers["Accept"]
    end

    test "does not include authorization header when llm_api_key is blank" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: nil)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      headers = adapter.send(:build_headers)

      assert_nil headers["Authorization"]
    end

    test "build_payload does not include tools key" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      adapter.send(:parse_messages_data!, { messages: [ { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] } ], first_message: true, context_changed: false })
      payload = adapter.send(:build_payload)

      assert_not payload.key?(:tools), "Tools key should not be present"
    end

    test "format_message_for_ws includes full context on first message" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "You are a helpful agent",
        context: {}
      )

      messages_data = {
        messages: [
          { role: "user", kind: :creative_context, parts: [ { text: "Creative (id: 42):\n# My Project" } ] },
          { role: "user", kind: :context_creative, parts: [ { text: "Context Creative (id: 41):\n# Dev Environment" } ] },
          { role: "user", kind: :trigger, parts: [ { text: "[Alice]: Follow-up question" } ] }
        ],
        first_message: true,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, messages_data)
      result = adapter.send(:format_message_for_ws)

      assert_includes result, "You are a helpful agent"
      assert_includes result, "Creative (id: 42):"
      assert_includes result, "Context Creative (id: 41):"
      assert_includes result, "[Alice]: Follow-up question"
    end

    test "format_message_for_ws sends all received messages (pure transport)" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      # SessionContextResolver already filtered to trigger-only for warm sessions
      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: nil,
        context: {}
      )

      messages_data = {
        messages: [
          { role: "user", kind: :trigger, parts: [ { text: "[Alice]: Follow-up question" } ] }
        ],
        first_message: false,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, messages_data)
      result = adapter.send(:format_message_for_ws)

      assert_not_includes result, "You are a helpful agent"
      assert_equal "[Alice]: Follow-up question", result
    end

    test "format_message_for_ws includes all messages when provided" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "System prompt",
        context: {}
      )

      messages_data = {
        messages: [
          { role: "user", kind: :creative_context, parts: [ { text: "Creative (id: 100):\n# Updated" } ] },
          { role: "user", kind: :trigger, parts: [ { text: "[Bob]: Hello" } ] }
        ],
        first_message: false,
        context_changed: true
      }

      adapter.send(:parse_messages_data!, messages_data)
      result = adapter.send(:format_message_for_ws)

      assert_includes result, "System prompt"
      assert_includes result, "Creative (id: 100):"
      assert_includes result, "[Bob]: Hello"
    end

    test "build_ws_chat_payload includes image attachments from all messages" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "You are a helpful agent",
        context: {}
      )

      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("\x89PNG\r\n\x1a\n" + "\x00" * 100),
        filename: "test.png",
        content_type: "image/png"
      )

      messages_data = {
        messages: [
          { role: "user", kind: :creative_context, parts: [ { text: "Creative (id: 42):\n# My Project" } ] },
          { role: "user", kind: :trigger, parts: [ { text: "What is this?" }, { image: blob } ] }
        ],
        first_message: true,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, messages_data)
      result = adapter.send(:build_ws_chat_payload)

      assert_includes result[:message], "You are a helpful agent"
      assert_includes result[:message], "Creative (id: 42):"
      assert_includes result[:message], "What is this?"
      assert_equal 1, result[:attachments].size
      attachment = result[:attachments].first
      assert_equal "image", attachment[:type]
      assert_equal "image/png", attachment[:mimeType]
    ensure
      blob&.purge
    end

    test "format_message_for_ws returns empty string for empty trigger" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      adapter.send(:parse_messages_data!, { messages: [], first_message: true, context_changed: false })
      result = adapter.send(:format_message_for_ws)
      # Only system prompt when no trigger
      assert_equal "Test", result
    end

    test "websocket_available? returns true when classes are defined" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      assert adapter.send(:websocket_available?)
    end

    test "chat accepts plain Array input for standalone callers" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com",
                             llm_api_key: "test-key")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      # Simulate what AiClientExtension.normalize_messages_input produces
      # from a standalone caller like CompressJob
      normalized = {
        messages: [ { role: "user", text: "Summarize this", kind: :trigger } ],
        first_message: true,
        context_changed: false
      }

      adapter.send(:parse_messages_data!, normalized)
      payload = adapter.send(:build_payload)

      # Should include system prompt (first_message) + the trigger
      assert_equal 2, payload[:messages].length
      assert_equal "system", payload[:messages][0][:role]
      assert_equal "user", payload[:messages][1][:role]
    end

    test "chat uses websocket when transport is auto" do
      original_transport = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "auto"

      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com",
                             llm_api_key: "test-key")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      assert adapter.send(:websocket_available?)

      ws_called = false
      adapter.define_singleton_method(:chat_via_websocket) do |&_blk|
        ws_called = true
        nil
      end

      adapter.chat({ messages: [ { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] } ], first_message: true, context_changed: false })
      assert ws_called, "Should use WebSocket when transport is auto"
    ensure
      CollavreOpenclaw.config.transport = original_transport
    end

    test "chat uses http when transport is http even if websocket available" do
      original_transport = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "http"

      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com",
                             llm_api_key: "test-key")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      assert adapter.send(:websocket_available?)

      http_called = false
      adapter.define_singleton_method(:chat_via_http) do |&_blk|
        http_called = true
        nil
      end

      adapter.chat({ messages: [ { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] } ], first_message: true, context_changed: false })
      assert http_called, "Should use HTTP when transport is http"
    ensure
      CollavreOpenclaw.config.transport = original_transport
    end

    # Did the request ever reach the gateway? Collavre::AiClient answers this
    # for its own provider path (#last_handoff_failed?) so DeliveryRecord can
    # tell a turn that delivered nothing from one that answered; this adapter
    # path bypasses that method entirely — it streams an error and returns nil
    # just the same — so it has to answer for itself. The proxy is the same
    # one: nothing streamed means nothing was handed over.
    def http_adapter(user: nil)
      user ||= build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com",
                               llm_api_key: "test-key")
      OpenclawAdapter.new(user: user, system_prompt: "Test", context: {})
    end

    def messages_data
      { messages: [ { role: "user", kind: :trigger, parts: [ { text: "Hello" } ] } ],
        first_message: true, context_changed: false }
    end

    def with_http_transport
      original = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "http"
      yield
    ensure
      CollavreOpenclaw.config.transport = original
    end

    test "a chat with no gateway configured never reached the provider" do
      adapter = http_adapter(user: build_test_user(gateway_url: nil, llm_api_key: "test-key"))

      assert_nil adapter.chat(messages_data)
      assert_predicate adapter, :last_handoff_failed?
    end

    test "a chat with no API key never reached the provider" do
      adapter = http_adapter(user: build_test_user(gateway_url: "https://test-gateway.com"))

      assert_nil adapter.chat(messages_data)
      assert_predicate adapter, :last_handoff_failed?
    end

    test "an error before anything streamed is a failed handoff" do
      with_http_transport do
        adapter = http_adapter
        adapter.define_singleton_method(:stream_response) do |_payload, &_blk|
          raise CollavreOpenclaw::ConnectionError, "gateway unreachable"
        end

        assert_nil adapter.chat(messages_data)
        assert_predicate adapter, :last_handoff_failed?
      end
    end

    # Control, and the boundary: the gateway had the payload and answered part
    # of it. That is a truncated reply with the ordinary retry beside it, and
    # the comments the turn swallowed did reach the agent.
    test "an error after content streamed is not a failed handoff" do
      with_http_transport do
        adapter = http_adapter
        adapter.define_singleton_method(:stream_response) do |_payload, &blk|
          blk.call("half an ans")
          raise CollavreOpenclaw::ConnectionError, "gateway went away"
        end

        streamed = +""
        adapter.chat(messages_data) { |chunk| streamed << chunk }

        assert_includes streamed, "half an ans", "premise: the gateway answered part of it"
        assert_not adapter.last_handoff_failed?
      end
    end

    # Control: an empty answer returns nil too, and nil is what the failure
    # returns — which is why the return value cannot carry this and a flag has
    # to. A gateway that took the payload and said nothing delivered it.
    test "a chat that reached the gateway and answered nothing is not a failed handoff" do
      with_http_transport do
        adapter = http_adapter
        adapter.define_singleton_method(:stream_response) { |_payload, &_blk| nil }

        assert_nil adapter.chat(messages_data)
        assert_not adapter.last_handoff_failed?
      end
    end

    # One #chat, two transports. The WebSocket answered part of the payload and
    # then dropped, and the HTTP attempt behind it failed before yielding
    # anything of its own. Each transport keeps its own buffer, so neither one
    # can answer "did anything get through this chat" — and the gateway did
    # have the payload, so restoring the comments this turn swallowed would
    # answer them a second time.
    test "a websocket that streamed before a failing http fallback is not a failed handoff" do
      adapter = http_adapter
      adapter.define_singleton_method(:stream_response) do |_payload, &_blk|
        raise CollavreOpenclaw::ConnectionError, "gateway unreachable"
      end

      streamed = +""
      with_websocket_dropping_after(delta: "half an ans") do
        adapter.chat(messages_data) { |chunk| streamed << chunk }
      end

      assert_includes streamed, "half an ans", "premise: the gateway answered part of it over the websocket"
      assert_not adapter.last_handoff_failed?
    end

    # The gateway answers chat.send with a run id before a single event is
    # waited for, and that answer is the handoff: it has the whole payload and
    # the run may already be calling tools. A run that is then quiet until the
    # read timeout, behind an HTTP attempt that fails before yielding, has cost
    # an answer — restoring the comments this turn swallowed would put them to
    # an agent that already has them.
    test "a websocket run the gateway accepted before a failing http fallback is not a failed handoff" do
      adapter = http_adapter
      adapter.define_singleton_method(:stream_response) do |_payload, &_blk|
        raise CollavreOpenclaw::ConnectionError, "gateway unreachable"
      end

      with_websocket_dropping_after(delta: nil) do
        assert_nil adapter.chat(messages_data)
      end

      assert_not adapter.last_handoff_failed?
    end

    # Control: a gateway that never answered chat.send at all really is a failed
    # handoff, which is what holds the fix to the acknowledgement rather than to
    # the fallback having happened. send_rpc raises on a read timeout and on an
    # RPC error, so this is the only shape in which the run id never arrives.
    test "a websocket the gateway never acknowledged before a failing http fallback is a failed handoff" do
      adapter = http_adapter
      adapter.define_singleton_method(:stream_response) do |_payload, &_blk|
        raise CollavreOpenclaw::ConnectionError, "gateway unreachable"
      end

      with_websocket_dropping_after(delta: nil, acknowledged: false) do
        assert_nil adapter.chat(messages_data)
      end

      assert_predicate adapter, :last_handoff_failed?
    end

    # A raise from the caller's streaming block is the turn aborting itself —
    # AgentLifecycleManager#check_cancelled! raises from the delta callback on a
    # terminal task status or an overrun turn deadline — not the transport
    # failing. Falling back to HTTP would hand the gateway the same payload a
    # second time and hold the worker thread through a whole second attempt.
    test "a cancellation raised mid-stream over websocket unwinds instead of falling back to http" do
      adapter = http_adapter
      fallback_called = false
      adapter.define_singleton_method(:chat_via_http) do |&_blk|
        fallback_called = true
        nil
      end

      with_websocket_streaming(delta: "partial") do
        assert_raises(Collavre::CancelledError) do
          adapter.chat(messages_data) { |_chunk| raise Collavre::CancelledError }
        end
      end

      assert_not fallback_called, "cancellation must unwind, not start an HTTP fallback"
    end

    test "a non-cancellation streaming callback error does not start an HTTP fallback" do
      adapter = http_adapter
      callback_error = RuntimeError.new("task reload failed")
      fallback_called = false
      adapter.define_singleton_method(:chat_via_http) do |&_blk|
        fallback_called = true
        nil
      end

      raised = with_websocket_streaming(delta: "partial") do
        assert_raises(RuntimeError) do
          adapter.chat(messages_data) { |_chunk| raise callback_error }
        end
      end

      assert_same callback_error, raised
      refute fallback_called,
             "an application callback failure is not a WebSocket transport failure"
    end

    # Same turn-abort raise on the HTTP transport. The block raises only once —
    # in production check_cancelled! is throttled, so the "OpenClaw Error"
    # yielded by the rescue would not re-raise; without the re-raise the
    # cancellation is swallowed into the reply text and the turn ends normally.
    test "a cancellation raised mid-stream over http is re-raised, not swallowed" do
      with_http_transport do
        adapter = http_adapter
        adapter.define_singleton_method(:stream_response) do |_payload, &blk|
          blk.call("partial")
        end

        cancelled = false
        assert_raises(Collavre::CancelledError) do
          adapter.chat(messages_data) do |_chunk|
            next if cancelled

            cancelled = true
            raise Collavre::CancelledError
          end
        end
      end
    end

    # The caller's streaming block fires only on text, and an OpenClaw run does
    # its tool work on the gateway — so a tool-only run never crosses the
    # block. The lifecycle check injected at construction is the adapter path's
    # substitute for the RubyLLM tool-call boundary: it must reach chat_send,
    # and its raise must unwind like a block raise, not start a fallback.
    test "the websocket transport polls the injected lifecycle check" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: -> { raise Collavre::CancelledError }
      )
      fallback_called = false
      adapter.define_singleton_method(:chat_via_http) do |&_blk|
        fallback_called = true
        nil
      end

      original = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "auto"
      begin
        client = Object.new
        # A run that goes quiet doing gateway-side tool work: chat.send is
        # acknowledged, then no events. The real client's lifecycle poll is
        # what raises here; the fake honors the same contract.
        client.define_singleton_method(:chat_send) do |session_key:, message:, attachments:, on_run_id:, lifecycle_check: nil, &_blk|
          on_run_id&.call("run-#{SecureRandom.hex(4)}")
          lifecycle_check&.call
          flunk "lifecycle_check must raise before any event handling"
        end
        manager = Object.new
        manager.define_singleton_method(:connection_for) { |_user| client }

        CollavreOpenclaw::ConnectionManager.stub(:instance, manager) do
          assert_raises(Collavre::CancelledError) { adapter.chat(messages_data) { |_chunk| } }
        end
      ensure
        CollavreOpenclaw.config.transport = original
      end

      assert_not fallback_called, "a lifecycle raise must unwind, not start an HTTP fallback"
    end

    test "a non-cancellation lifecycle error does not start an HTTP fallback" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      lifecycle_error = RuntimeError.new("task reload failed")
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: -> { raise lifecycle_error }
      )
      fallback_called = false
      adapter.define_singleton_method(:chat_via_http) do |&_blk|
        fallback_called = true
        nil
      end

      original = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "auto"
      begin
        client = Object.new
        client.define_singleton_method(:chat_send) do |session_key:, message:, attachments:, on_run_id:, lifecycle_check: nil, &_blk|
          on_run_id&.call("run-#{SecureRandom.hex(4)}")
          lifecycle_check&.call
        end
        manager = Object.new
        manager.define_singleton_method(:connection_for) { |_user| client }

        raised = CollavreOpenclaw::ConnectionManager.stub(:instance, manager) do
          assert_raises(RuntimeError) { adapter.chat(messages_data) { |_chunk| } }
        end
        assert_same lifecycle_error, raised
      ensure
        CollavreOpenclaw.config.transport = original
      end

      refute fallback_called,
             "a lifecycle callback failure is not a WebSocket transport failure"
    end

    # The HTTP transport has no event loop to poll from; its checkpoint is the
    # SSE parser, which runs for every received chunk — including comment/tool
    # events that never yield text to the caller's block.
    test "the http sse parser crosses the injected lifecycle check on non-content chunks" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      checks = 0
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: -> { checks += 1 }
      )

      buffer = +"event: tool_use\ndata: {\"type\":\"tool_use\"}\n\n"
      adapter.send(:process_sse_buffer, buffer) { |_chunk| flunk "no text to yield" }

      assert_operator checks, :>=, 1,
        "a chunk with no caller-visible text must still cross the lifecycle check"
    end

    test "the http stream polls lifecycle before an unterminated SSE event completes" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      checks = 0
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: lambda {
          checks += 1
          raise Collavre::CancelledError
        }
      )

      request = OpenStruct.new(headers: {}, options: OpenStruct.new)
      request.define_singleton_method(:url) { |_endpoint| }
      on_data_returned = false
      connection = Object.new
      connection.define_singleton_method(:post) do |&configure|
        configure.call(request)
        body = +'data: {"type":"tool_use"'
        request.options.on_data.call(body, body.bytesize, OpenStruct.new(status: 200))
        on_data_returned = true
        OpenStruct.new(status: 200, headers: { "content-type" => "text/event-stream" }, body: body)
      end
      adapter.define_singleton_method(:build_connection) { connection }

      assert_raises(Collavre::CancelledError) do
        adapter.send(:stream_response, { messages: [] }) { |_chunk| flunk "no text to yield" }
      end

      assert_equal 1, checks
      assert_not on_data_returned,
                 "lifecycle must be checked from on_data instead of waiting for response completion"
      assert_not adapter.handed_off?,
                 "an unterminated SSE fragment does not prove the agent accepted the payload"
    end

    test "the http connection timeout is capped by the remaining turn deadline" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        request_timeout_seconds: -> { 60.0 }
      )

      assert_equal 60.0, adapter.send(:build_connection).options.timeout
    end

    test "the http sse parser records handoff before lifecycle cancellation" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      adapter = nil
      handed_off_at_check = false
      check = lambda do
        handed_off_at_check = adapter.handed_off?
        raise Collavre::CancelledError
      end
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: check
      )
      buffer = +"event: tool_use\ndata: {\"type\":\"tool_use\"}\n\n"

      assert_raises(Collavre::CancelledError) do
        adapter.send(:process_sse_buffer, buffer) { |_chunk| flunk "no text to yield" }
      end

      assert handed_off_at_check,
             "a successful HTTP event proves delivery before cancellation is observed"
      assert_predicate adapter, :handed_off?
    end

    test "a successful http json response records handoff before lifecycle cancellation" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      adapter = nil
      handed_off_at_check = false
      check = lambda do
        handed_off_at_check = adapter.handed_off?
        raise Collavre::CancelledError
      end
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: check
      )

      body = '{"choices":[{"message":{"content":"done"}}]}'
      request = OpenStruct.new(headers: {}, options: OpenStruct.new)
      request.define_singleton_method(:url) { |_endpoint| }
      connection = Object.new
      connection.define_singleton_method(:post) do |&configure|
        configure.call(request)
        env = OpenStruct.new(
          status: 200,
          response_headers: { "content-type" => "application/json" }
        )
        request.options.on_data.call(body, body.bytesize, env)
        OpenStruct.new(
          status: 200,
          headers: { "content-type" => "application/json" },
          body: body
        )
      end
      adapter.define_singleton_method(:build_connection) { connection }

      assert_raises(Collavre::CancelledError) do
        adapter.send(:stream_response, { messages: [] }) { |_chunk| }
      end

      assert handed_off_at_check,
             "a completed successful JSON response proves delivery before cancellation is observed"
      assert_predicate adapter, :handed_off?
    end

    test "the http sse parser checks lifecycle without treating a keepalive comment as handoff" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      adapter = nil
      handed_off_at_check = nil
      check = lambda do
        handed_off_at_check = adapter.handed_off?
        raise Collavre::CancelledError
      end
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: check
      )
      buffer = +": ping\n\n"

      assert_raises(Collavre::CancelledError) do
        adapter.send(:process_sse_buffer, buffer) { |_chunk| flunk "no text to yield" }
      end

      assert_equal false, handed_off_at_check,
                   "an SSE transport keepalive does not prove the agent received the payload"
      assert_not adapter.handed_off?
    end

    test "the http sse parser checks lifecycle before flushing a final partial event" do
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      checks = 0
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: -> { checks += 1 }
      )
      buffer = +'data: {"choices":[{"delta":{"content":"last"}}]}'
      streamed = +""

      adapter.send(:process_sse_buffer, buffer, final: true) { |chunk| streamed << chunk }

      assert_equal 1, checks
      assert_equal "last", streamed
      assert_empty buffer
    end

    test "an http timeout checks lifecycle before retrying the request" do
      assert_http_retry_checks_lifecycle(Faraday::TimeoutError.new("gateway went quiet"))
    end

    test "an http connection failure checks lifecycle before retrying the request" do
      assert_http_retry_checks_lifecycle(Faraday::ConnectionFailed.new("gateway unavailable"))
    end

    test "an http timeout rechecks lifecycle after retry backoff" do
      assert_http_retry_rechecks_after_backoff(Faraday::TimeoutError.new("gateway went quiet"))
    end

    test "an http connection failure rechecks lifecycle after retry backoff" do
      assert_http_retry_rechecks_after_backoff(Faraday::ConnectionFailed.new("gateway unavailable"))
    end

    private

    def assert_http_retry_checks_lifecycle(transport_error)
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      attempts = 0
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: -> { raise Collavre::CancelledError }
      )
      connection = Object.new
      connection.define_singleton_method(:post) do |&_block|
        attempts += 1
        raise transport_error
      end
      adapter.define_singleton_method(:build_connection) { connection }

      assert_raises(Collavre::CancelledError) do
        adapter.send(:stream_response, messages_data)
      end
      assert_equal 1, attempts, "a cancelled turn must not issue another provider request"
    end

    def assert_http_retry_rechecks_after_backoff(transport_error)
      user = build_test_user(gateway_url: "https://test-gateway.com", llm_api_key: "test-key")
      attempts = 0
      checks = 0
      adapter = OpenclawAdapter.new(
        user: user, system_prompt: "Test", context: {},
        lifecycle_check: lambda {
          checks += 1
          raise Collavre::CancelledError if checks >= 2
        }
      )
      connection = Object.new
      connection.define_singleton_method(:post) do |&_block|
        attempts += 1
        raise transport_error
      end
      adapter.define_singleton_method(:build_connection) { connection }
      adapter.define_singleton_method(:sleep) { |_seconds| }

      assert_raises(Collavre::CancelledError) do
        adapter.send(:stream_response, messages_data)
      end
      assert_equal 2, checks, "lifecycle must be checked on both sides of retry backoff"
      assert_equal 1, attempts, "cancellation during backoff must prevent a second provider request"
    end

    # Drive the real #chat_via_websocket: surface a run id the way the real
    # client does — WebsocketClient#chat_send calls on_run_id as soon as
    # chat.send comes back, before it waits for any event — then yield `delta`
    # if given, then drop the connection so the adapter falls through to
    # #chat_via_http. `acknowledged: false` is the gateway never answering
    # chat.send, which is where the real client raises before that callback.
    def with_websocket_dropping_after(delta:, acknowledged: true)
      original = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "auto"

      acked = acknowledged
      client = Object.new
      client.define_singleton_method(:chat_send) do |session_key:, message:, attachments:, on_run_id:, lifecycle_check: nil, &blk|
        on_run_id&.call("run-#{SecureRandom.hex(4)}") if acked
        blk.call({ state: "delta", text: delta }) if delta
        raise CollavreOpenclaw::TimeoutError, "gateway went quiet"
      end
      manager = Object.new
      manager.define_singleton_method(:connection_for) { |_user| client }

      CollavreOpenclaw::ConnectionManager.stub(:instance, manager) { yield }
    ensure
      CollavreOpenclaw.config.transport = original
    end

    # A websocket whose gateway acknowledges chat.send and streams `delta`
    # normally, so the caller's block is the only thing that can raise.
    def with_websocket_streaming(delta:)
      original = CollavreOpenclaw.config.transport
      CollavreOpenclaw.config.transport = "auto"

      client = Object.new
      client.define_singleton_method(:chat_send) do |session_key:, message:, attachments:, on_run_id:, lifecycle_check: nil, &blk|
        on_run_id&.call("run-#{SecureRandom.hex(4)}")
        blk.call({ state: "delta", text: delta })
        nil
      end
      manager = Object.new
      manager.define_singleton_method(:connection_for) { |_user| client }

      CollavreOpenclaw::ConnectionManager.stub(:instance, manager) { yield }
    ensure
      CollavreOpenclaw.config.transport = original
    end

    def build_test_user(gateway_url: nil, email: "test@example.com", llm_api_key: nil)
      user = Object.new
      user.define_singleton_method(:id) { 1 }
      gw = gateway_url
      user.define_singleton_method(:gateway_url) { gw }
      user_email = email
      user.define_singleton_method(:email) { user_email }
      api_key = llm_api_key
      user.define_singleton_method(:llm_api_key) { api_key }
      user
    end
  end

  # Integration test with real database
  class OpenclawAdapterIntegrationTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(
        email: "adapter-test@example.com",
        password: "password123",
        name: "Test Bot",
        gateway_url: "https://test-gateway.com"
      )
    end

    teardown do
      PendingCallback.delete_all
      @user&.destroy
    end

    test "creates pending callback when creative_id is present" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "Test",
        context: { creative_id: 456 }
      )

      # Stub the callback_url
      adapter.define_singleton_method(:callback_url) { "https://collavre.com/openclaw/callback/#{@user.id}" }

      assert_difference "PendingCallback.count", 1 do
        adapter.send(:build_user_context)
      end

      pending = PendingCallback.last
      assert_equal @user.id, pending.user_id
      assert_equal 456, pending.creative_id
      assert pending.nonce.present?
    end

    test "includes nonce in user context" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "Test",
        context: { creative_id: 789, topic_id: 111 }
      )

      adapter.define_singleton_method(:callback_url) { "https://collavre.com/openclaw/callback/#{@user.id}" }

      user_context = adapter.send(:build_user_context)

      assert user_context.start_with?("collavre:")
      context_json = JSON.parse(user_context.sub("collavre:", ""))

      assert context_json["callback_url"].present?
      assert context_json["callback_nonce"].present?
      assert_equal 789, context_json["creative_id"]
      assert_equal 111, context_json["topic_id"]
    end

    test "does not create pending callback without creative_id" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "Test",
        context: {}
      )

      adapter.define_singleton_method(:callback_url) { "https://collavre.com/openclaw/callback/#{@user.id}" }

      assert_no_difference "PendingCallback.count" do
        adapter.send(:build_user_context)
      end
    end

    test "does not create pending callback without callback_url" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "Test",
        context: { creative_id: 123 }
      )

      adapter.define_singleton_method(:callback_url) { nil }

      assert_no_difference "PendingCallback.count" do
        adapter.send(:build_user_context)
      end
    end

    test "session key includes user id" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "Test",
        context: { creative_id: 100, topic_id: 200 }
      )

      assert_includes adapter.session_key, @user.id.to_s
    end

    # --- run_id backfill / reclaim (cross-process duplicate suppression) ---

    test "persist_run_id_on_comment records the run for the solicited reply" do
      creative = Collavre::Creative.create!(description: "Reclaim creative", user: @user)
      reply = creative.comments.create!(user: @user, content: "Solicited reply")
      adapter = OpenclawAdapter.new(user: @user, system_prompt: "Test", context: { comment: reply })

      adapter.send(:persist_run_id_on_comment, "run-backfill")

      assert_equal reply.id, CollavreOpenclaw::ProcessedAiRun.comment_for("run-backfill")&.id
    ensure
      CollavreOpenclaw::ProcessedAiRun.where(run_id: "run-backfill").delete_all
      creative&.destroy
    end

    test "persist_run_id_on_comment reclaims the run and removes a proactive duplicate when it lost the race" do
      creative = Collavre::Creative.create!(description: "Reclaim creative", user: @user)
      # A proactive duplicate from another process already claimed the run_id.
      duplicate = creative.comments.create!(user: @user, content: "Proactive duplicate (no activity log)")
      CollavreOpenclaw::ProcessedAiRun.claim_proactive("run-race", duplicate)
      # The canonical solicited reply (carries the activity log) tries to record.
      reply = creative.comments.create!(user: @user, content: "Solicited reply with activity log")
      adapter = OpenclawAdapter.new(user: @user, system_prompt: "Test", context: { comment: reply })

      adapter.send(:persist_run_id_on_comment, "run-race")

      assert_equal reply.id, CollavreOpenclaw::ProcessedAiRun.comment_for("run-race")&.id,
                   "solicited reply should own the run"
      assert_not Collavre::Comment.exists?(duplicate.id), "proactive duplicate should be removed"
    ensure
      CollavreOpenclaw::ProcessedAiRun.where(run_id: "run-race").delete_all
      creative&.destroy
    end
  end
end
