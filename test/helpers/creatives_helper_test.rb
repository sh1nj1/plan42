require "test_helper"

class CreativesHelperTest < ActionView::TestCase
  include CreativesHelper
  test "markdown_links_to_html converts markdown link to HTML" do
    input = "Check [link](https://example.com)"
    expected = "Check <a href=\"https://example.com\">link</a>"
    assert_equal expected, markdown_links_to_html(input)
  end

  test "html_links_to_markdown converts HTML link to markdown" do
    input = "See <a href=\"https://example.com\">example</a> for details"
    expected = "See [example](https://example.com) for details"
    assert_equal expected, html_links_to_markdown(input)
  end

  test "markdown list items are single line" do
    user = users(:one)
    creative = Creative.create!(user: user, description: "<div>Item</div>\n")
    markdown = render_creative_tree_markdown([ creative ], 5)
    assert_equal "* Item\n", markdown
  end

  test "bold markdown converts to html and back" do
    md = "This is **bold** text"
    html = markdown_links_to_html(md)
    assert_equal "This is <strong>bold</strong> text", html
    back = html_links_to_markdown(html)
    assert_equal "This is **bold** text", back
  end

  test "escaped characters round trip" do
    md = "A \\*star\\* example"
    html = markdown_links_to_html(md)
    assert_equal "A *star* example", html
    back = html_links_to_markdown(html)
    assert_equal "A \\*star\\* example", back
  end

  test "base64 image link converts" do
    md = "Image: ![alt](data:image/png;base64,AAA)"
    html = markdown_links_to_html(md)
    assert_equal "Image: <img src=\"data:image/png;base64,AAA\" alt=\"alt\" />", html
    back = html_links_to_markdown(html)
    assert_equal "Image: ![alt](data:image/png;base64,AAA)", back
  end
end
