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
      # Account needs to support multiple calls for channel_id check
      account = Object.new
      def account.api_endpoint; "https://test-gateway.com/v1/chat/completions"; end
      def account.api_token; "test-token"; end
      def account.channel_id; "test-channel"; end
      def account.gateway_url; "https://test-gateway.com"; end

      user = Object.new
      user.define_singleton_method(:id) { 1 }
      user.define_singleton_method(:openclaw_account) { account }

      adapter = OpenclawAdapter.new(
        user: user,
        system_prompt: "Test prompt",
        context: { creative: { id: 123 } }
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
      assert_equal "collavre:test-channel", payload[:user]
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
  end
end
