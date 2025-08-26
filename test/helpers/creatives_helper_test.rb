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
    md = "A \\*star\\* \\-dash\\- \\#hash\\# \\~tilde\\~ \\+plus\\+ example"
    html = markdown_links_to_html(md)
    assert_equal "A *star* -dash- #hash# ~tilde~ +plus+ example", html
    back = html_links_to_markdown(html)
    assert_equal md, back
  end

  test "base64 image link converts" do
    md = "Image: ![alt](data:image/png;base64,aGk=)"
    html = markdown_links_to_html(md)
    assert_match(/<action-text-attachment[^>]+content-type=\"image\/png\"[^>]+caption=\"alt\"[^>]*>/, html)
    back = html_links_to_markdown(html)
    assert_equal md, back
  end

  test "reference style base64 image converts" do
    md = "Look ![][img1]\n\n[img1]: <data:image/png;base64,aGk=>"
    html = markdown_links_to_html(md)
    assert_match(/<action-text-attachment[^>]+content-type=\"image\/png\"[^>]*>/, html)
    back = html_links_to_markdown(html)
    assert_equal "Look ![](data:image/png;base64,aGk=)", back
  end

  test "trix_view_only renders readonly trix editor" do
    creative = Creative.create!(user: users(:one), description: "<div>Example</div>")
    html = trix_view_only(creative.effective_description(nil, false))
    assert_includes html, "<trix-editor"
    assert_includes html, "readonly"
  end
end
