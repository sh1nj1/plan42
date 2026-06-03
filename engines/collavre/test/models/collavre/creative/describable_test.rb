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

      test "GFM task list checkboxes survive sanitization" do
        source = "- [ ] todo\n- [x] done\n"

        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: source)
        creative = Creative.last

        assert_match %r{<input[^>]*type="checkbox"[^>]*disabled}, creative.description
        assert_match %r{<input[^>]*checked[^>]*}, creative.description
      end

      test "non-checkbox input tags are stripped from description" do
        Creative.create!(
          user: @user,
          description: %(<p>hi <input type="text" value="x"> <input type="submit"></p>)
        )
        creative = Creative.last

        refute_match %r{<input}, creative.description
        assert_includes creative.description, "hi"
      end

      test "inline data-URI image is rewritten to blob path in stored markdown_source" do
        pixel_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        data_uri = "data:image/png;base64,#{pixel_b64}"

        source = "before ![pixel](#{data_uri}) after"

        Creative.create!(user: @user, content_type_input: "markdown", markdown_source: source)
        creative = Creative.last

        stored = creative.data["markdown_source"]
        refute_includes stored, "data:image/png;base64,", "data URI should be rewritten out of stored markdown_source"
        assert_match %r{!\[pixel\]\(/rails/active_storage/blobs/[^)]+\)}, stored

        blob_count_after_first = ActiveStorage::Blob.count

        # Subsequent text edits around the (now blob-backed) image must not
        # re-import the data URI as a fresh blob.
        edited_source = stored.sub("before", "edited before")
        creative.update!(content_type_input: "markdown", markdown_source: edited_source)
        creative.reload

        assert_equal blob_count_after_first, ActiveStorage::Blob.count,
                     "editing surrounding text must not create new blobs"
        assert_includes creative.data["markdown_source"], "edited before"
      end
    end
  end
end
