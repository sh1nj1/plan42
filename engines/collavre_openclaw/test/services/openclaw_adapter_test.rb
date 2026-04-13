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

    test "build_ws_chat_payload includes image attachments from trigger only" do
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

    private

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
  end
end
