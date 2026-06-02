require "test_helper"

module Collavre
  class Creative
    class DescribableTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
      end

      test "markdown_source setter normalizes CRLF and CR to LF" do
        creative = Creative.new(user: @user)

        creative.markdown_source = "a\r\nb\rc\nd"
        assert_equal "a\nb\nc\nd", creative.markdown_source
      end

      test "markdown_source setter leaves non-string values untouched" do
        creative = Creative.new(user: @user)

        creative.markdown_source = nil
        assert_nil creative.markdown_source
      end

      test "convert_markdown_to_html persists normalized markdown_source" do
        creative = Creative.new(user: @user, content_type_input: "markdown", markdown_source: "line1\r\nline2\r\n")
        creative.save!

        assert_equal "line1\nline2\n", creative.data["markdown_source"]
        assert_equal "markdown", creative.data["content_type"]
      end
    end
  end
end
