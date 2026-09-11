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

    # Lenient prefix character tests
    test "extract_name after colon" do
      assert_equal "AgentB", MentionParser.extract_name("결과:@AgentB: 완료")
    end

    test "extract_name after period" do
      assert_equal "AgentB", MentionParser.extract_name("done.@AgentB: check")
    end

    test "extract_name after comma" do
      assert_equal "AgentB", MentionParser.extract_name("ok,@AgentB: check")
    end

    test "extract_name after semicolon" do
      assert_equal "AgentB", MentionParser.extract_name("ok;@AgentB: check")
    end

    test "extract_name after newline" do
      assert_equal "AgentB", MentionParser.extract_name("line1\n@AgentB: check")
    end

    test "extract_all_names finds mentions after punctuation" do
      text = "결과:@Agent1: 완료,@Agent2: 확인.@Agent3: 검토"
      names = MentionParser.extract_all_names(text)
      assert_includes names, "Agent1"
      assert_includes names, "Agent2"
      assert_includes names, "Agent3"
    end

    test "extract_name does not match after alphanumeric" do
      # email-like patterns should not match
      assert_nil MentionParser.extract_name("user@agent: test")
    end

    # --- Multi-mention extraction (ordered) ---

    test "extract_all_names returns every mention in text order" do
      assert_equal [ "Vrex", "Astra" ],
        MentionParser.extract_all_names("@Vrex please review\n@Astra: confirm")
    end

    test "extract_all_names does not double-count a canonical mention at start" do
      assert_equal [ "Astra" ], MentionParser.extract_all_names("@Astra: confirm")
    end

    test "extract_all_names keeps multi-word canonical names whole" do
      assert_equal [ "John Doe", "GitHub PR Analyzer" ],
        MentionParser.extract_all_names("@John Doe: report\n@GitHub PR Analyzer: review")
    end

    test "extract_all_names keeps at signs inside canonical names" do
      assert_equal [ "ops@example.com", "Astra" ],
        MentionParser.extract_all_names("@ops@example.com: investigate\n@Astra: review")
    end

    test "extract_all_names stops a canonical name at a newline" do
      # Without a newline boundary the lazy name match swallows the whole first
      # line plus the next "@", yielding one unresolvable name instead of two.
      assert_equal [ "Astra" ], MentionParser.extract_all_names("plain line\n@Astra: confirm")
    end

    test "extract_name returns the first mention in text order" do
      assert_equal "Vrex", MentionParser.extract_name("@Vrex please review\n@Astra: confirm")
    end

    test "extract_all_names first entry always equals extract_name" do
      [
        "@Astra: confirm",
        "@Vrex please review",
        "@Vrex please review\n@Astra: confirm",
        "@John Doe: report\n@Astra: confirm",
        "hello @Astra: confirm"
      ].each do |text|
        assert_equal MentionParser.extract_name(text),
          MentionParser.extract_all_names(text).first,
          "mismatch for #{text.inspect}"
      end
    end

    test "resolve_all_users preserves mention order" do
      first = User.create!(name: "OrderFirst", email: "order_first@example.com", password: "password")
      second = User.create!(name: "OrderSecond", email: "order_second@example.com", password: "password")

      resolved = MentionParser.resolve_all_users("@OrderFirst done\n@OrderSecond: your turn")

      assert_equal [ first.id, second.id ], resolved.map(&:id)
    end

    test "resolve_all_users finds a canonical mention whose name contains an at sign" do
      user = User.create!(name: "ops@example.com", email: "ops_mention@example.com", password: "password")

      assert_equal [ user.id ], MentionParser.resolve_all_users("@ops@example.com: investigate").map(&:id)
    end

    test "resolve_all_users resolves every mention in a single query" do
      names = 5.times.map do |i|
        User.create!(name: "BatchAgent#{i}", email: "batch_agent_#{i}@example.com", password: "password").name
      end
      text = names.map { |name| "@#{name}: go" }.join("\n")

      selects = capture_user_selects { MentionParser.resolve_all_users(text) }

      assert_equal 1, selects.size,
        "expected one lookup for #{names.size} mentions, got #{selects.size}:\n#{selects.join("\n")}"
    end

    test "resolve_all_users keeps mention order when resolved in one query" do
      # Descending ids so a query returning rows in primary-key order cannot
      # accidentally match the mention order.
      third = User.create!(name: "BatchOrderC", email: "batch_order_c@example.com", password: "password")
      second = User.create!(name: "BatchOrderB", email: "batch_order_b@example.com", password: "password")
      first = User.create!(name: "BatchOrderA", email: "batch_order_a@example.com", password: "password")

      resolved = MentionParser.resolve_all_users("@BatchOrderC: one\n@BatchOrderB: two\n@BatchOrderA: three")

      assert_equal [ third.id, second.id, first.id ], resolved.map(&:id)
    end

    test "resolve_all_users matches a name stored with surrounding whitespace" do
      user = User.create!(name: "  PaddedAgent  ", email: "padded_agent@example.com", password: "password")

      assert_equal [ user.id ], MentionParser.resolve_all_users("@PaddedAgent: go").map(&:id)
    end

    test "resolve_all_users resolves a mention of a name written with line breaks" do
      # The canonical mention is "@" + name + ":", so a stored line break would
      # split the name across the newline boundary the parser enforces. Names
      # are normalized to a single line so the canonical form stays parseable.
      user = User.create!(name: "Line\nBreak Agent", email: "line_break_agent@example.com", password: "password")

      assert_equal [ user.id ], MentionParser.resolve_all_users("@#{user.name}: investigate").map(&:id)
    end

    private

    def capture_user_selects
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        next if payload[:name] == "SCHEMA" || payload[:cached]

        queries << sql if sql.match?(/\ASELECT\b/i) && sql.match?(/\bFROM\s+"?users"?/i)
      end

      begin
        yield
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      queries
    end
  end
end
