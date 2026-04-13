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

    # creative_children_level tests

    test "creative_children_level returns default 6 when agent_conf is blank" do
      @user.agent_conf = nil
      assert_equal 6, @user.creative_children_level
    end

    test "creative_children_level returns default 6 when set to nil" do
      @user.agent_conf = "context:\n  creative_children_level:"
      assert_equal 6, @user.creative_children_level
    end

    test "creative_children_level returns 0 when set to 0" do
      @user.agent_conf = "context:\n  creative_children_level: 0"
      assert_equal 0, @user.creative_children_level
    end

    test "creative_children_level returns configured value" do
      @user.agent_conf = "context:\n  creative_children_level: 2"
      assert_equal 2, @user.creative_children_level
    end

    test "creative_children_level coerces string to integer" do
      @user.agent_conf = "context:\n  creative_children_level: '3'"
      assert_equal 3, @user.creative_children_level
    end

    # supports_session? tests

    test "supports_session? auto-detects true for openclaw vendor" do
      @user.llm_vendor = "openclaw"
      @user.agent_conf = nil
      assert @user.supports_session?
    end

    test "supports_session? auto-detects false for non-openclaw vendor" do
      @user.llm_vendor = "google"
      @user.agent_conf = nil
      assert_not @user.supports_session?
    end

    test "supports_session? explicit true overrides auto-detect" do
      @user.llm_vendor = "google"
      @user.agent_conf = "session:\n  enabled: true"
      assert @user.supports_session?
    end

    test "supports_session? explicit false overrides auto-detect for openclaw" do
      @user.llm_vendor = "openclaw"
      @user.agent_conf = "session:\n  enabled: false"
      assert_not @user.supports_session?
    end

    test "supports_session? returns false when llm_vendor is nil" do
      @user.llm_vendor = nil
      @user.agent_conf = nil
      assert_not @user.supports_session?
    end
  end
end
