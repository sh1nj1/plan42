require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "linkify_urls converts URLs to links" do
    text = "Visit http://example.com"
    expected = 'Visit <a target="_blank" rel="noopener" href="http://example.com">http://example.com</a>'
    assert_equal expected, linkify_urls(text)
  end

  test "render_markdown converts markdown to HTML" do
    text = "**bold**\nhttp://example.com and [link](http://example.org)"
    expected = "<p><strong>bold</strong><br>\n<a href=\"http://example.com\" target=\"_blank\" rel=\"noopener\">http://example.com</a> and <a href=\"http://example.org\" target=\"_blank\" rel=\"noopener\">link</a></p>\n"
    assert_equal expected, render_markdown(text)
  end
end
