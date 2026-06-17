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

    test "markdown_to_html renders a single newline as a hard break" do
      # Mirrors the JS renderer (marked breaks:true): consecutive rich-editor
      # lines are stored one-per-line and must render as <br>, not be joined.
      html = MarkdownConverter.markdown_to_html("abc\ndef")
      assert_includes html, "<br"
      assert_includes html, "abc"
      assert_includes html, "def"
      # Stays a single paragraph (line break, not a paragraph break).
      assert_equal 1, html.scan("<p>").length
    end

    test "markdown_to_html keeps a blank line as a paragraph break" do
      html = MarkdownConverter.markdown_to_html("abc\n\ndef")
      assert_equal 2, html.scan("<p>").length
    end

    test "markdown_to_html renders a non-breaking-space line as a visible blank line" do
      # The Lexical serializer stores a user's empty line as a U+00A0 line so it
      # survives Markdown rendering instead of collapsing. With hardbreaks the
      # nbsp line becomes a blank visual row inside one paragraph (a<br>nbsp<br>b),
      # and N empty lines render as N blank rows.
      html = MarkdownConverter.markdown_to_html("abc\n\u00A0\ndef")
      assert_equal 1, html.scan("<p>").length
      assert_equal 2, html.scan("<br").length
      assert_includes html, "\u00A0"

      two = MarkdownConverter.markdown_to_html("abc\n\u00A0\n\u00A0\ndef")
      assert_equal 3, two.scan("<br").length
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

    test "markdown_to_html handles inline data URI with parenthesized title" do
      input = %Q(![pic](#{PNG_DATA_URI} (caption)))
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "/rails/active_storage/blobs/"
        refute_includes html, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites inline data URI with parenthesized title and preserves title" do
      input = %Q(![pic](#{PNG_DATA_URI} (caption)))
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        refute_includes rewritten, "data:image/png"
        assert_includes rewritten, "(caption)"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside fenced code blocks untouched" do
      input = "Sample:\n\n```md\n![pic](#{PNG_DATA_URI})\n```\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside tilde-fenced code blocks untouched" do
      input = "Sample:\n\n~~~\n![pic](#{PNG_DATA_URI})\n~~~\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images leaves reference-style data URI definitions inside fenced code blocks untouched" do
      input = "Sample:\n\n```md\n![pic][p]\n\n[p]: #{PNG_DATA_URI}\n```\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside inline code spans untouched" do
      input = "Use `![pic](#{PNG_DATA_URI})` in your Markdown."
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites a real image but leaves a code-sampled one alone" do
      input = "Real: ![pic](#{PNG_DATA_URI})\n\nSample:\n\n```md\n![pic](#{PNG_DATA_URI})\n```\n"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        # The code block content survives intact.
        assert_includes rewritten, "```md\n![pic](#{PNG_DATA_URI})\n```"
      end
    end

    test "markdown_to_html leaves data URIs inside fenced code blocks as literal code" do
      input = "Sample:\n\n```md\n![pic](#{PNG_DATA_URI})\n```\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "<pre"
        assert_includes html, "data:image/png"
        refute_includes html, "/rails/active_storage/blobs/"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside 4-space indented code blocks untouched" do
      input = "Sample:\n\n    ![pic](#{PNG_DATA_URI})\n\nAfter.\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside tab-indented code blocks untouched" do
      input = "Sample:\n\n\t![pic](#{PNG_DATA_URI})\n\nAfter.\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images leaves reference-style data URI defs inside indented code blocks untouched" do
      input = "Sample:\n\n    [p]: #{PNG_DATA_URI}\n    ![pic][p]\n\nAfter.\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites a real image but leaves an indented-code-sampled one alone" do
      input = "Real: ![pic](#{PNG_DATA_URI})\n\nSample:\n\n    ![pic](#{PNG_DATA_URI})\n\nAfter.\n"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        assert_includes rewritten, "    ![pic](#{PNG_DATA_URI})"
      end
    end

    test "markdown_to_html leaves data URIs inside 4-space indented code blocks as literal code" do
      input = "Sample:\n\n    ![pic](#{PNG_DATA_URI})\n\nAfter.\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "<pre"
        assert_includes html, "data:image/png"
        refute_includes html, "/rails/active_storage/blobs/"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside unclosed fenced code blocks untouched" do
      input = "Sample:\n\n```md\n![pic](#{PNG_DATA_URI})\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images leaves data URIs inside unclosed tilde-fenced code blocks untouched" do
      input = "Sample:\n\n~~~\n![pic](#{PNG_DATA_URI})\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_equal input, rewritten
        assert_includes rewritten, "data:image/png"
      end
    end

    test "rewrite_data_uri_images rewrites a real image before an unclosed fence but leaves the fenced sample alone" do
      input = "Real: ![pic](#{PNG_DATA_URI})\n\nSample:\n\n```md\n![pic](#{PNG_DATA_URI})\n"
      assert_difference -> { ActiveStorage::Blob.count }, +1 do
        rewritten = MarkdownConverter.rewrite_data_uri_images(input)
        assert_includes rewritten, "/rails/active_storage/blobs/"
        assert_includes rewritten, "```md\n![pic](#{PNG_DATA_URI})\n"
      end
    end

    test "markdown_to_html leaves data URIs inside unclosed fenced code blocks as literal code" do
      input = "Sample:\n\n```md\n![pic](#{PNG_DATA_URI})\n"
      assert_no_difference -> { ActiveStorage::Blob.count } do
        html = MarkdownConverter.markdown_to_html(input)
        assert_includes html, "<pre"
        assert_includes html, "data:image/png"
        refute_includes html, "/rails/active_storage/blobs/"
      end
    end
  end
end
