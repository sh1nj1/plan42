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

      test "description-only update on markdown creative demotes to html" do
        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: "# old")
        creative = Creative.last
        assert_equal "markdown", creative.data["content_type"]
        assert_equal "# old", creative.data["markdown_source"]

        creative.update!(description: "<h1>new from tool</h1>")
        creative.reload

        assert_nil creative.data["content_type"]
        assert_nil creative.data["markdown_source"]
        assert_includes creative.description, "new from tool"
      end

      test "non-description update on markdown creative preserves markdown metadata" do
        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: "# keep")
        creative = Creative.last
        assert_equal "markdown", creative.data["content_type"]

        creative.update!(progress: 1.0)
        creative.reload

        assert_equal "markdown", creative.data["content_type"]
        assert_equal "# keep", creative.data["markdown_source"]
      end
    end
  end
end
