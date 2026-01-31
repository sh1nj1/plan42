require "test_helper"
require "minitest/mock"

module CollavreOpenclaw
  class OpenclawAdapterTest < ActiveSupport::TestCase
    def setup
      @user = Minitest::Mock.new
      @account = Minitest::Mock.new

      @account.expect :api_endpoint, "https://test-gateway.com/api/v1/chat"
      @account.expect :api_token, "test-token"
      @account.expect :channel_id, "test-channel"

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
      adapter = OpenclawAdapter.new(
        user: @user,
        system_prompt: "Test prompt",
        context: { creative: { id: 123 } }
      )

      messages = [
        { role: "user", parts: [{ text: "Hello" }] },
        { role: "model", parts: [{ text: "Hi there!" }] }
      ]

      payload = adapter.send(:build_payload, messages, [])

      assert_equal "Test prompt", payload[:system_prompt]
      assert_equal 2, payload[:messages].length
      assert_equal "user", payload[:messages][0][:role]
      assert_equal "Hello", payload[:messages][0][:content]
      assert payload[:stream]
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
