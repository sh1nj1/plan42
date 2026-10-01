require_relative "test_helper"

module CollavreTranslation
  class ProtectedContentTest < ActiveSupport::TestCase
    test "restores code links mentions HTML and literal placeholders exactly" do
      source = "Please review @정순오: @Astra: @GitHub PR Analyzer: @someone https://example.com/x `code` [Creative](https://example.com/creatives/7) <b>hello</b> COLLAVRE_TOKEN_9_END\n```ruby\nputs 'hi'\n```\n~~~js\nalert(1)\n~~~"
      protected = ProtectedContent.new(source)
      refute_includes protected.masked, "puts 'hi'"
      refute_includes protected.masked, "https://example.com"
      assert_equal source.sub("Please review", "검토해 주세요"), protected.restore(protected.masked.sub("Please review", "검토해 주세요"))
    end

    test "fences protect embedded delimiters mismatched closers and unclosed blocks" do
      blocks = [
        "```js\nconst marker = \"```\";\nconst secret = 1;\n```",
        "````js\n```\nconst secret = 1;\n`````",
        "~~~js\n```\nconst marker = \"~~~\";\nconst secret = 1;\n~~~~",
        "   ```js\nconst secret = 1;\n   ```",
        "```js\nconst secret = 1;"
      ]
      blocks.each do |block|
        source = "Translate this\n#{block}"
        protected = ProtectedContent.new(source)
        assert_equal "Translate this\nCOLLAVRE_TOKEN_0_END", protected.masked
        assert_equal source, protected.restore(protected.masked)
      end
    end

    test "protects complete code spans with matching backtick runs" do
      spans = [ "``foo ` bar``", "`foo\nbar`", "``foo\n`bar`\nbaz``", "```foo `` bar```", "`foo `` bar`" ]
      spans.each do |span|
        source = "Translate this #{span} please"
        protected = ProtectedContent.new(source)
        assert_equal "Translate this COLLAVRE_TOKEN_0_END please", protected.masked
        assert_equal source, protected.restore(protected.masked)
      end
    end

    test "unmatched backticks remain prose without preventing later code spans" do
      source = "Translate ` unmatched ``code`` please"
      protected = ProtectedContent.new(source)
      assert_equal "Translate ` unmatched COLLAVRE_TOKEN_0_END please", protected.masked
      assert_equal source, protected.restore(protected.masked)
      assert_equal "Translate ``unclosed` please", ProtectedContent.new("Translate ``unclosed` please").masked
    end

    test "rejects missing duplicated and invented placeholders" do
      protected = ProtectedContent.new("Hello `code`")
      [ "Hello", "COLLAVRE_TOKEN_0_END COLLAVRE_TOKEN_0_END", "COLLAVRE_TOKEN_99_END" ].each do |text|
        assert_raises(ArgumentError) { protected.restore(text) }
      end
    end

    test "rejects placeholder literals the model invented" do
      assert_raises(ArgumentError) { ProtectedContent.new("Hello").restore("안녕하세요 COLLAVRE_TOKEN_N") }
      assert_raises(ArgumentError) { ProtectedContent.new("Hello `code`").restore("COLLAVRE_TOKEN_0_END COLLAVRE_TOKEN_") }
    end

    test "protects literal placeholder prefixes and nonnumeric suffixes" do
      source = "Hello COLLAVRE_TOKEN_N COLLAVRE_TOKEN_ COLLAVRE_TOKEN_12suffix COLLAVRE_TOKEN_name_2"
      protected = ProtectedContent.new(source)
      assert_equal "Hello COLLAVRE_TOKEN_0_END COLLAVRE_TOKEN_1_END COLLAVRE_TOKEN_2_END COLLAVRE_TOKEN_3_END", protected.masked
      assert_equal source.sub("Hello", "안녕하세요"), protected.restore(protected.masked.sub("Hello", "안녕하세요"))
      assert_raises(ArgumentError) { protected.restore("COLLAVRE_TOKEN_N COLLAVRE_TOKEN_1_END COLLAVRE_TOKEN_2_END COLLAVRE_TOKEN_3_END") }
      assert_raises(ArgumentError) { protected.restore("#{protected.masked} COLLAVRE_TOKEN_extra2") }
    end

    test "restores protected content immediately followed by digits" do
      [ "H<sub>2</sub>O is water", "see `v`2 now", "@bob:5 items", "[a](b)2024 plan" ].each do |source|
        protected = ProtectedContent.new(source)
        assert_equal source, protected.restore(protected.masked)
      end
    end

    test "rejects old or malformed placeholders even with an adjacent suffix" do
      protected = ProtectedContent.new("Hello `code`")
      [ "COLLAVRE_TOKEN_0abc", "COLLAVRE_TOKEN_02", "COLLAVRE_TOKEN_0_EN", "COLLAVRE_TOKEN_0_END COLLAVRE_TOKEN_extra2" ].each do |result|
        assert_raises(ArgumentError) { protected.restore(result) }
      end
      assert_equal "Hello `code`abc", protected.restore("Hello COLLAVRE_TOKEN_0_ENDabc")
    end

    test "reports whether the source has protected tokens" do
      assert ProtectedContent.new("Hello `code`").tokens?
      assert_not ProtectedContent.new("Hello").tokens?
    end

    test "text without protected tokens passes through" do
      assert_equal "안녕하세요", ProtectedContent.new("Hello").restore("안녕하세요")
    end
  end
end
