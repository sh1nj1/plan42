# frozen_string_literal: true

require "test_helper"

module Collavre
  class UserAgentConfTest < ActiveSupport::TestCase
    setup do
      @user = users(:ai_bot)
    end

    test "returns defaults when agent_conf is blank" do
      @user.agent_conf = nil
      assert_equal 50, @user.chat_history_limit
      assert_equal 100_000, @user.chat_history_size_limit
    end

    test "parses valid YAML config" do
      @user.agent_conf = "context:\n  chat_history: 5\n  chat_history_size: 2000"
      assert_equal 5, @user.chat_history_limit
      assert_equal 2000, @user.chat_history_size_limit
    end

    test "merges partial config with defaults" do
      @user.agent_conf = "context:\n  chat_history: 10"
      assert_equal 10, @user.chat_history_limit
      assert_equal 100_000, @user.chat_history_size_limit
    end

    test "returns defaults for invalid YAML" do
      @user.agent_conf = "context: {invalid: [}"
      assert_equal 50, @user.chat_history_limit
      assert_equal 100_000, @user.chat_history_size_limit
    end

    test "returns defaults for empty YAML" do
      @user.agent_conf = ""
      assert_equal 50, @user.chat_history_limit
    end
  end
end
