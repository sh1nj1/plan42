# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class CommentFormatterTest < ActiveSupport::TestCase
    # Lightweight doubles: the formatter only reads #content and #user.display_name.
    FakeUser    = Struct.new(:display_name)
    FakeComment = Struct.new(:content, :user)

    def body_for(content, author: "정순오")
      CommentFormatter.outbound_body(FakeComment.new(content, FakeUser.new(author)))
    end

    test "prefixes the author display name" do
      assert_equal "\\[정순오\\]: hello world", body_for("hello world")
    end

    # Regression: an unescaped "[name]: word" is a Markdown link reference
    # definition (label + destination) and Linear renders it as an EMPTY string
    # when the content is a single token. Escaping the brackets keeps the whole
    # line as literal text regardless of word count.
    test "single-word content is not swallowed as a link reference definition" do
      assert_equal "\\[정순오\\]: hello", body_for("hello")
    end

    test "falls back to raw content when the author has no name" do
      assert_equal "hello", body_for("hello", author: nil)
    end

    test "handles nil content without raising" do
      assert_equal "\\[정순오\\]: ", body_for(nil)
    end
  end
end
