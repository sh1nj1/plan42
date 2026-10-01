require_relative "test_helper"

module CollavreTranslation
  class ProtectedContentTest < ActiveSupport::TestCase
    test "restores code links mentions HTML and literal placeholders exactly" do
      source = "Please review @정순오: @Astra: @GitHub PR Analyzer: @someone https://example.com/x `code` [Creative](https://example.com/creatives/7) <b>hello</b> COLLAVRE_TOKEN_9\n```ruby\nputs 'hi'\n```\n~~~js\nalert(1)\n~~~"
      protected = ProtectedContent.new(source)
      refute_includes protected.masked, "puts 'hi'"
      refute_includes protected.masked, "https://example.com"
      assert_equal source.sub("Please review", "검토해 주세요"), protected.restore(protected.masked.sub("Please review", "검토해 주세요"))
    end

    test "rejects missing duplicated and invented placeholders" do
      protected = ProtectedContent.new("Hello `code`")
      [ "Hello", "COLLAVRE_TOKEN_0 COLLAVRE_TOKEN_0", "COLLAVRE_TOKEN_99" ].each do |text|
        assert_raises(ArgumentError) { protected.restore(text) }
      end
    end

    test "text without protected tokens passes through" do
      assert_equal "안녕하세요", ProtectedContent.new("Hello").restore("안녕하세요")
    end
  end
end
