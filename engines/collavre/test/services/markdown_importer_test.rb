require "test_helper"

class MarkdownImporterTest < ActiveSupport::TestCase
  test "skips horizontal rules" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      # Header
      Some content
      ---
      More content
      ***
      Final content
      ___
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    descriptions = created.map { |c| c.reload.description }

    # Should have: Header, Some content, More content, Final content
    assert_equal 4, created.size, "Horizontal rules should be skipped"
    assert descriptions.none? { |d| d.strip == "---" }, "--- should not create a Creative"
    assert descriptions.none? { |d| d.strip == "***" }, "*** should not create a Creative"
    assert descriptions.none? { |d| d.strip == "___" }, "___ should not create a Creative"
  end

  test "imports fenced code blocks as single creative with pre/code tags" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      # Header
      ```ruby
      def hello
        puts "world"
      end
      ```
      Some text after
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    # Should have: Header, code block, Some text after
    assert_equal 3, created.size, "Code block should be a single Creative"

    code_creative = created[1].reload
    html = code_creative.description

    assert_includes html, "<pre><code", "Code block should have pre/code tags"
    assert_includes html, 'class="language-ruby"', "Code block should preserve language"
    assert_includes html, "def hello", "Code block should contain the code"
    assert_includes html, "puts", "Code block should contain all lines"
  end

  test "handles code blocks without language specifier" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ```
      plain code
      more lines
      ```
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    assert_equal 1, created.size

    html = created.first.reload.description
    assert_includes html, "<pre><code>"
    assert_includes html, "plain code"
    assert_not_includes html, 'class="language-'
  end

  test "escapes html in code blocks" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ```html
      <div class="test">Hello</div>
      ```
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    html = created.first.reload.description

    assert_includes html, "&lt;div"
    assert_includes html, "&gt;"
    assert_not_includes html, "<div class=\"test\">"
  end

  test "imports markdown tables as html" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      | Name | Count |
      | ---- | ----- |
      | Alice | 3 |
      | Bob | 5 |
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)
    table_creative = created.last
    table_creative.reload

    html = table_creative.description
    assert_includes html, "<table>"
    assert_includes html, "Alice"
    assert_includes html, "5"
    assert_includes html, "<table>"
  end

  test "does not convert table syntax inside fenced code blocks" do
    user = users(:one)
    parent = Creative.create!(user: user, description: "Parent")
    markdown = <<~MD
      ```
      | key | value |
      | --- | ----- |
      ```

      | Name | Count |
      | ---- | ----- |
      | Alice | 3 |
    MD

    created = MarkdownImporter.import(markdown, parent: parent, user: user)

    html_fragments = created.map { |creative| creative.reload.description }

    code_block_html = html_fragments.find { |html| html.include?("| key | value |") }
    assert_not_nil code_block_html, "Expected code block content to be preserved"

    table_htmls = html_fragments.select { |html| html.include?("<table>") }
    assert_equal 1, table_htmls.size, "Only actual tables should be converted to HTML"
  end
end
