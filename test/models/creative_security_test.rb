require "test_helper"

class CreativeSecurityTest < ActiveSupport::TestCase
  test "sanitizes description by removing script tags on save" do
    malicious_html = "Hello <script>alert('xss')</script> world"
    creative = Creative.create!(description: malicious_html, sequence: 0)

    # Should strip script tags but keep text
    assert_equal "Hello alert('xss') world", creative.description.strip
  end

  test "sanitizes description by removing event handlers" do
    malicious_html = "<div onclick='alert(1)'>Click me</div>"
    creative = Creative.create!(description: malicious_html, sequence: 0)

    # Should remove onclick attribute
    assert_no_match(/onclick/, creative.description)
    assert_match(/Click me/, creative.description)
  end

  test "allows safe html tags" do
    safe_html = "<b>Bold</b> and <i>Italic</i>"
    creative = Creative.create!(description: safe_html, sequence: 0)

    assert_equal safe_html, creative.description
  end
end
