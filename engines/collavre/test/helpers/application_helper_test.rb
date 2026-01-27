require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "linkify_urls converts URLs to links" do
    text = "Visit http://example.com"
    expected = 'Visit <a target="_blank" rel="noopener" href="http://example.com">http://example.com</a>'
    assert_equal expected, linkify_urls(text)
  end
end
