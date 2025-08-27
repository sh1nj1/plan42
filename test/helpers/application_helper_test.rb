require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "linkify_urls converts URLs to links" do
    text = "Visit http://example.com"
    expected = 'Visit <a href="http://example.com" target="_blank" rel="noopener">http://example.com</a>'
    assert_equal expected, linkify_urls(text)
  end

  test "linkify_urls escapes html" do
    text = "<script>alert('x')</script> https://example.com"
    result = linkify_urls(text)
    assert_includes result, "&lt;script&gt;alert('x')&lt;/script&gt;"
    assert_includes result, '<a href="https://example.com" target="_blank" rel="noopener">https://example.com</a>'
  end
end
