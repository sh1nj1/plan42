require "test_helper"

module CollavreGithub
  class PrTopicLinkParserTest < ActiveSupport::TestCase
    test "extracts topic id from absolute URL in PR body" do
      body = "Closes #1.\n\nTopic: https://collavre.example.com/creatives/123/topics/456"
      assert_equal 456, PrTopicLinkParser.call(body)
    end

    test "extracts topic id from path-only reference" do
      body = "Linked: /creatives/123/topics/789"
      assert_equal 789, PrTopicLinkParser.call(body)
    end

    test "returns nil when no topic link present" do
      assert_nil PrTopicLinkParser.call("just a regular PR body")
    end

    test "returns nil for blank body" do
      assert_nil PrTopicLinkParser.call(nil)
      assert_nil PrTopicLinkParser.call("")
    end

    test "returns first match when multiple topic links present" do
      body = "A: /creatives/1/topics/10 B: /creatives/2/topics/20"
      assert_equal 10, PrTopicLinkParser.call(body)
    end
  end
end
