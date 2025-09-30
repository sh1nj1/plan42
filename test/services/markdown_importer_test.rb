require "test_helper"

class MarkdownImporterTest < ActiveSupport::TestCase
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

    html = table_creative.rich_text_description.body.to_html
    assert_includes html, "<table>"
    assert_includes html, "<td>Alice</td>"
    assert_includes html, "<td>5</td>"
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

    html_fragments = created.map { |creative| creative.reload.rich_text_description.body.to_html }

    code_block_html = html_fragments.find { |html| html.include?("| key | value |") }
    assert_not_nil code_block_html, "Expected code block content to be preserved"

    table_htmls = html_fragments.select { |html| html.include?("<table>") }
    assert_equal 1, table_htmls.size, "Only actual tables should be converted to HTML"
  end
end
