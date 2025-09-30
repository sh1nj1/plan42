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
end
