require "test_helper"
require "minitest/mock"

module CollavreOpenclaw
  class OpenclawAdapterTest < ActiveSupport::TestCase
    def setup
      @user = Minitest::Mock.new
      @account = Minitest::Mock.new

      @user.expect :id, 1
      @user.expect :openclaw_account, @account
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
      account = build_test_account
      user = build_test_user(account)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: { creative_id: 123 }
      )

      messages = [
        { role: "user", parts: [{ text: "Hello" }] },
        { role: "model", parts: [{ text: "Hi there!" }] }
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
      assert_equal "openclaw", payload[:model]
    end

    test "normalizes message roles correctly" do
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "",
        context: {}
      )

      assert_equal "user", adapter.send(:normalize_role, "user")
      assert_equal "assistant", adapter.send(:normalize_role, "model")
      assert_equal "assistant", adapter.send(:normalize_role, "assistant")
      assert_equal "system", adapter.send(:normalize_role, "system")
      assert_equal "user", adapter.send(:normalize_role, "unknown")
    end

    test "builds user context with callback_url" do
      account = build_test_account(callback_url: "https://collavre.com/openclaw/callback/123")
      user = build_test_user(account)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      user_context = adapter.send(:build_user_context)

      assert user_context.start_with?("collavre:")
      context_json = JSON.parse(user_context.sub("collavre:", ""))
      assert_equal "https://collavre.com/openclaw/callback/123", context_json["callback_url"]
    end

    test "builds user context with creative_id" do
      account = build_test_account
      user = build_test_user(account)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 456 }
      )

      user_context = adapter.send(:build_user_context)
      context_json = JSON.parse(user_context.sub("collavre:", ""))

      assert_equal 456, context_json["creative_id"]
    end

    test "builds user context with creative object" do
      account = build_test_account
      user = build_test_user(account)

      creative = OpenStruct.new(id: 789)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative: creative }
      )

      user_context = adapter.send(:build_user_context)
      context_json = JSON.parse(user_context.sub("collavre:", ""))

      assert_equal 789, context_json["creative_id"]
    end

    test "builds user context with thread_id" do
      account = build_test_account
      user = build_test_user(account)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: { creative_id: 123, thread_id: 999 }
      )

      user_context = adapter.send(:build_user_context)
      context_json = JSON.parse(user_context.sub("collavre:", ""))

      assert_equal 999, context_json["thread_id"]
    end

    test "returns callback_url from account" do
      account = build_test_account(callback_url: "https://example.com/callback/1")
      user = build_test_user(account)

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "",
        context: {}
      )

      assert_equal "https://example.com/callback/1", adapter.callback_url
    end

    private

    def build_test_account(callback_url: nil)
      account = Object.new
      account.define_singleton_method(:api_endpoint) { "https://test-gateway.com/v1/chat/completions" }
      account.define_singleton_method(:api_token) { "test-token" }
      account.define_singleton_method(:channel_id) { "test-channel" }
      account.define_singleton_method(:gateway_url) { "https://test-gateway.com" }
      account.define_singleton_method(:callback_url) { callback_url }
      account.define_singleton_method(:id) { 123 }
      account
    end

    def build_test_user(account)
      user = Object.new
      user.define_singleton_method(:id) { 1 }
      user.define_singleton_method(:openclaw_account) { account }
      user
    end
  end
end
