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

    test "builds correct payload format" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages = [
        { role: "user", parts: [ { text: "Hello" } ] },
        { role: "model", parts: [ { text: "Hi there!" } ] }
      ]

      payload = adapter.send(:build_payload, messages, [])

      # System prompt is added as first message
      assert_equal 3, payload[:messages].length
      assert_equal "system", payload[:messages][0][:role]
      assert_equal "Test prompt", payload[:messages][0][:content]
      assert_equal "user", payload[:messages][1][:role]
      assert_equal "Hello", payload[:messages][1][:content]
      assert_equal "assistant", payload[:messages][2][:role]
      assert_equal "Hi there!", payload[:messages][2][:content]
      assert payload[:stream]
      # Model includes agent_id derived from user email (test@example.com -> test)
      assert_equal "openclaw:test", payload[:model]
    end

    test "includes agent_id derived from user email in model field" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "ai-bot@collavre.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages = [ { role: "user", content: "Hello" } ]

      payload = adapter.send(:build_payload, messages, [])

      assert_equal "openclaw:ai-bot", payload[:model]
    end

    test "uses plain openclaw model when user email is blank" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: nil)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages = [ { role: "user", content: "Hello" } ]

      payload = adapter.send(:build_payload, messages, [])

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

    test "formats messages with sender attribution" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      messages = [
        { role: "user", content: "Hello", sender_name: "Shinji" },
        { role: "assistant", content: "Hi there!" },
        { role: "user", content: "Question", sender_name: "Jane" }
      ]

      formatted = adapter.send(:format_messages, messages)

      assert_equal "[Shinji]: Hello", formatted[0][:content]
      assert_equal "Hi there!", formatted[1][:content]
      assert_equal "[Jane]: Question", formatted[2][:content]
    end

    test "does not add sender attribution to assistant messages" do
      user = build_test_user(gateway_url: "https://test-gateway.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      messages = [
        { role: "assistant", content: "Response", sender_name: "AI Bot" }
      ]

      formatted = adapter.send(:format_messages, messages)

      # Should NOT have sender attribution for assistant
      assert_equal "Response", formatted[0][:content]
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

    test "includes tools in payload when provided" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages = [ { role: "user", content: "Hello" } ]
      tools = [
        {
          type: "function",
          function: {
            name: "search_documents",
            description: "Search for documents",
            parameters: {
              type: "object",
              properties: {
                query: { type: "string", description: "Search query" }
              },
              required: [ "query" ]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "get_weather",
            description: "Get weather information",
            parameters: {
              type: "object",
              properties: {
                location: { type: "string" }
              }
            }
          }
        }
      ]

      payload = adapter.send(:build_payload, messages, tools)

      assert payload[:tools].present?, "Tools should be included in payload"
      assert_equal 2, payload[:tools].length
      assert_equal "search_documents", payload[:tools][0][:function][:name]
      assert_equal "get_weather", payload[:tools][1][:function][:name]
    end

    test "does not include tools key when tools array is empty" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages = [ { role: "user", content: "Hello" } ]

      payload = adapter.send(:build_payload, messages, [])

      assert_not payload.key?(:tools), "Tools key should not be present when empty"
    end

    test "does not include tools key when tools is nil" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      messages = [ { role: "user", content: "Hello" } ]

      payload = adapter.send(:build_payload, messages, nil)

      assert_not payload.key?(:tools), "Tools key should not be present when nil"
    end

    test "converts MCP tool format to OpenAI format" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      mcp_tool = {
        name: "search_documents",
        description: "Search for documents",
        params: [
          { name: "query", type: "string", description: "Search query", required: true },
          { name: "limit", type: "integer", description: "Max results", required: false }
        ]
      }

      result = adapter.send(:convert_mcp_tool_to_openai_format, mcp_tool)

      assert_equal "function", result[:type]
      assert_equal "search_documents", result[:function][:name]
      assert_equal "Search for documents", result[:function][:description]
      assert_equal "object", result[:function][:parameters][:type]
      assert_equal "string", result[:function][:parameters][:properties]["query"][:type]
      assert_equal "integer", result[:function][:parameters][:properties]["limit"][:type]
      assert_includes result[:function][:parameters][:required], "query"
      assert_not_includes result[:function][:parameters][:required], "limit"
    end

    test "format_tools passes through OpenAI format tools unchanged" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      openai_tool = {
        type: "function",
        function: {
          name: "get_weather",
          description: "Get weather",
          parameters: { type: "object", properties: {}, required: [] }
        }
      }

      result = adapter.send(:format_tools, [ openai_tool ])

      assert_equal 1, result.length
      assert_equal openai_tool, result.first
    end

    test "format_tools converts MCP format tools to OpenAI format" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: {}
      )

      mcp_tool = {
        name: "calculate",
        description: "Perform calculation",
        params: [
          { name: "expression", type: "string", required: true }
        ]
      }

      result = adapter.send(:format_tools, [ mcp_tool ])

      assert_equal 1, result.length
      assert_equal "function", result.first[:type]
      assert_equal "calculate", result.first[:function][:name]
    end

    test "format_message_for_ws extracts last user message" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      messages = [
        { role: "user", parts: [ { text: "First question" } ] },
        { role: "model", parts: [ { text: "Answer" } ] },
        { role: "user", parts: [ { text: "Follow-up question" } ] }
      ]

      result = adapter.send(:format_message_for_ws, messages)
      assert_equal "Follow-up question", result
    end

    test "format_message_for_ws includes creative context on first message" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      # First message in session — no assistant replies yet
      messages = [
        { role: "user", parts: [ { text: "Creative:\n# My Project" } ] },
        { role: "user", parts: [ { text: "What do you think?" } ] }
      ]

      result = adapter.send(:format_message_for_ws, messages)
      assert_includes result, "Creative:\n# My Project"
      assert_includes result, "What do you think?"
    end

    test "format_message_for_ws does NOT repeat creative context on follow-up messages" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      # Follow-up — assistant has already replied, so context was sent before
      messages = [
        { role: "user", parts: [ { text: "Creative:\n# My Project" } ] },
        { role: "user", parts: [ { text: "First question" } ] },
        { role: "assistant", parts: [ { text: "Here's my answer" } ] },
        { role: "user", parts: [ { text: "Follow-up question" } ] }
      ]

      result = adapter.send(:format_message_for_ws, messages)
      assert_equal "Follow-up question", result
      assert_not_includes result, "Creative:"
    end

    test "format_message_for_ws returns empty string for no user messages" do
      user = build_test_user(gateway_url: "https://test-gateway.com", email: "test@example.com")

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test",
        context: {}
      )

      messages = [
        { role: "system", content: "System prompt" }
      ]

      result = adapter.send(:format_message_for_ws, messages)
      assert_equal "", result
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
