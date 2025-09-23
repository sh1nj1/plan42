require "test_helper"

class CommentLinkFormatterTest < ActiveSupport::TestCase
  NullLogger = Struct.new(:warn, :info) do
    def warn(*) end
    def info(*) end
  end

  test "replaces plain urls with markdown links using fetched titles" do
    fetcher = ->(_url) { { title: "Example Domain" } }
    formatter = CommentLinkFormatter.new("Check https://example.com", metadata_fetcher: fetcher, logger: NullLogger.new)

    assert_equal "Check [Example Domain](https://example.com)", formatter.format
  end

  test "preserves trailing punctuation outside the link" do
    fetcher = ->(_url) { { title: "Example" } }
    formatter = CommentLinkFormatter.new("Visit https://example.com.", metadata_fetcher: fetcher, logger: NullLogger.new)

    assert_equal "Visit [Example](https://example.com).", formatter.format
  end

  test "does not alter existing markdown links" do
    fetcher = Minitest::Mock.new
    fetcher.expect(:call, { title: "Another" }, [ "https://another.example" ])

    content = "Already [Saved](https://example.com) and https://another.example"
    formatter = CommentLinkFormatter.new(content, metadata_fetcher: fetcher, logger: NullLogger.new)

    assert_equal "Already [Saved](https://example.com) and [Another](https://another.example)", formatter.format
    fetcher.verify
  end

  test "returns original content when metadata missing" do
    fetcher = ->(_url) { {} }
    formatter = CommentLinkFormatter.new("https://example.com", metadata_fetcher: fetcher, logger: NullLogger.new)

    assert_equal "https://example.com", formatter.format
  end

  test "swallows errors from metadata fetcher" do
    fetcher = lambda do |_url|
      raise StandardError, "boom"
    end
    logger = Minitest::Mock.new
    logger.expect(:warn, nil, [String])

    formatter = CommentLinkFormatter.new("https://example.com", metadata_fetcher: fetcher, logger: logger)

    assert_equal "https://example.com", formatter.format
    logger.verify
  end
end
