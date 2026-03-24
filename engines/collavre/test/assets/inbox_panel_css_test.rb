require "test_helper"

class InboxPanelCssTest < ActiveSupport::TestCase
  test "defines open state for small screens" do
    css = File.read(Collavre::Engine.root.join("app/assets/stylesheets/collavre/gnb.css"))
    assert_includes css, "@media (max-width: 360px)"

    pattern = /#inbox-panel\.slide-panel\.open\s*\{[^\}]*right:\s*0;[^\}]*\}/
    assert_match pattern, css
  end
end
