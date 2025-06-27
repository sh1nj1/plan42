require "test_helper"

class CreativeMarkdownServiceTest < ActiveSupport::TestCase
  test "import parses markdown table into html creative" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    data = "# Title\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
    result = CreativeMarkdownService.import(file: StringIO.new(data), parent: nil, user: user)

    assert result[:success]
    assert_equal 2, result[:created].size
    creative = Creative.find(result[:created].last)
    assert_match %r{<table>.*<th>A</th>.*<th>B</th>}m, creative.rich_text_description.body.to_html

    Current.reset
  end

  test "export converts html table to markdown" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    html = "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td>2</td></tr></tbody></table>"
    creative = Creative.create!(user: user, description: html)

    md = CreativeMarkdownService.export(parent_id: creative.id)

    assert_includes md, "|A | B|"
    assert_includes md, "|1 | 2|"

    Current.reset
  end

  test "import handles table with trailing pipes" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    data = "| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n"
    result = CreativeMarkdownService.import(file: StringIO.new(data), parent: nil, user: user)

    assert result[:success]
    creative = Creative.find(result[:created].last)
    html = creative.rich_text_description.body.to_html
    assert_includes html, "<th>A</th>"
    assert_includes html, "<th>B</th>"
    assert_includes html, "<th>C</th>"

    Current.reset
  end
end
