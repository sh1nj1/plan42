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
end
