require "test_helper"

module Collavre
  class MarkdownConverterTest < ActiveSupport::TestCase
    test "markdown_to_html converts links" do
      input = "Check [link](https://example.com)"
      result = MarkdownConverter.markdown_to_html(input)
      assert_includes result, '<a href="https://example.com">link</a>'
    end

    test "html_to_markdown converts links" do
      input = 'See <a href="https://example.com">example</a> for details'
      expected = "See [example](https://example.com) for details"
      assert_equal expected, MarkdownConverter.html_to_markdown(input)
    end

    test "markdown_to_html handles nil" do
      assert_equal "", MarkdownConverter.markdown_to_html(nil)
    end

    test "html_to_markdown handles nil" do
      assert_equal "", MarkdownConverter.html_to_markdown(nil)
    end

    test "bold round trips" do
      md = "This is **bold** text"
      html = MarkdownConverter.markdown_to_html(md)
      assert_includes html, "<strong>bold</strong>"
      back = MarkdownConverter.html_to_markdown(html)
      assert_equal md, back
    end

    test "escaped characters round trip" do
      md = "A \\*star\\* \\-dash\\- \\#hash\\# \\~tilde\\~ \\+plus\\+ example"
      html = MarkdownConverter.markdown_to_html(md)
      assert_includes html, "star"
      assert_includes html, "dash"
    end

    test "table_block? detects valid markdown table" do
      table = "| A | B |\n| --- | --- |\n| 1 | 2 |"
      assert MarkdownConverter.table_block?(table)
    end

    test "table_block? rejects non-table text" do
      refute MarkdownConverter.table_block?("just text")
      refute MarkdownConverter.table_block?(nil)
    end

    test "table_to_markdown converts HTML table" do
      html = <<~HTML
        <table>
          <thead><tr><th>Name</th><th>Age</th></tr></thead>
          <tbody><tr><td>Alice</td><td>30</td></tr></tbody>
        </table>
      HTML
      result = MarkdownConverter.table_to_markdown(html)
      assert_includes result, "| Name | Age |"
      assert_includes result, "| Alice | 30 |"
    end

    test "table_to_markdown escapes pipe in cells" do
      html = '<table><thead><tr><th>Expr</th></tr></thead><tbody><tr><td>A | B</td></tr></tbody></table>'
      result = MarkdownConverter.table_to_markdown(html)
      assert_includes result, 'A \| B'
    end

    test "html bold with attributes converts to markdown" do
      input = '<strong class="highlight">bold</strong> text'
      assert_equal "**bold** text", MarkdownConverter.html_to_markdown(input)
    end

    # 1x1 transparent PNG
    PNG_DATA_URI = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=".freeze

    test "markdown_to_html handles bare reference-style data URI" do
      input = "Hello ![pic][p]\n\n[p]: #{PNG_DATA_URI}\n"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "/rails/active_storage/blobs/"
        refute_includes html, "data:image/png"
      end
    end

    test "markdown_to_html handles bare reference-style data URI with title" do
      input = %Q(Hello ![pic][p]\n\n[p]: #{PNG_DATA_URI} "caption"\n)
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "/rails/active_storage/blobs/"
        refute_includes html, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites bare reference-style data URI" do
      input = "Hello ![pic][p]\n\n[p]: #{PNG_DATA_URI}\n"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        refute_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites bare reference-style data URI with title" do
      input = %Q(Hello ![pic][p]\n\n[p]: #{PNG_DATA_URI} "caption"\n)
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        refute_includes rewritten, "data:image/png"
        assert_includes rewritten, '"caption"'
      end
    end

    test "markdown_to_html handles inline data URI with title" do
      input = %Q(Hello ![pic](#{PNG_DATA_URI} "caption"))
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "/rails/active_storage/blobs/"
        refute_includes html, "data:image/png"
      end
    end

    test "markdown_to_html handles inline data URI with single-quoted title" do
      input = %Q(![pic](#{PNG_DATA_URI} 'cap'))
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "/rails/active_storage/blobs/"
        refute_includes html, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites inline data URI with title and preserves title" do
      input = %Q(![pic](#{PNG_DATA_URI} "caption"))
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        refute_includes rewritten, "data:image/png"
        assert_includes rewritten, '"caption"'
      end
    end

    test "rewrite_data_uri_images rewrites inline data URI without title" do
      input = "![pic](#{PNG_DATA_URI})"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        refute_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images still handles angle-bracket reference form" do
      input = "Hello ![pic][p]\n\n[p]: <#{PNG_DATA_URI}>\n"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        refute_includes rewritten, "data:image/png"
      end
    end
  end
end
