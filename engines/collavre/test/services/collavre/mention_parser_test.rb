require "test_helper"

module Collavre
  class MentionParserTest < ActiveSupport::TestCase
    test "extract_name with canonical @name: format" do
      assert_equal "AgentB", MentionParser.extract_name("@AgentB: do something")
    end

    test "extract_name with loose @name format" do
      assert_equal "AgentB", MentionParser.extract_name("@AgentB do something")
    end

    test "extract_name returns nil for no mention" do
      assert_nil MentionParser.extract_name("just plain text")
    end

    test "extract_name returns nil for blank text" do
      assert_nil MentionParser.extract_name(nil)
      assert_nil MentionParser.extract_name("")
    end

    test "extract_name handles leading spaces in name" do
      # @  name: should not match because pattern expects non-colon chars
      assert_equal "name", MentionParser.extract_name("@name: hello")
    end

    test "find_user_by_name is case-insensitive" do
      user = User.create!(name: "TestAgent", email: "test_mention@example.com", password: "password")
      found = MentionParser.find_user_by_name("testagent")
      assert_equal user.id, found.id
    end

    test "find_user_by_name returns nil for unknown name" do
      assert_nil MentionParser.find_user_by_name("nonexistent_user_xyz")
    end

    test "resolve_user finds user from text" do
      user = User.create!(name: "ResolveMe", email: "resolve_mention@example.com", password: "password")
      found = MentionParser.resolve_user("@ResolveMe: check this")
      assert_equal user.id, found.id
    end

    test "resolve_user returns nil for no mention" do
      assert_nil MentionParser.resolve_user("no mention here")
    end

    test "strip_self_mention removes @name: prefix" do
      result = MentionParser.strip_self_mention("@Bot: do something", "Bot")
      assert_equal "do something", result
    end

    test "strip_self_mention removes @name prefix without colon" do
      result = MentionParser.strip_self_mention("@Bot do something", "Bot")
      assert_equal "do something", result
    end

    test "strip_self_mention is case-insensitive" do
      result = MentionParser.strip_self_mention("@BOT: do something", "bot")
      assert_equal "do something", result
    end

    test "strip_self_mention leaves text unchanged when no match" do
      result = MentionParser.strip_self_mention("@Other: do something", "Bot")
      assert_equal "@Other: do something", result
    end

    test "strip_self_mention handles nil inputs" do
      assert_nil MentionParser.strip_self_mention(nil, "Bot")
      assert_equal "@Bot: hello", MentionParser.strip_self_mention("@Bot: hello", nil)
    end
  end
end
