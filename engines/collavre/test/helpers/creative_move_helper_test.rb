require "test_helper"

class CreativeMoveHelperTest < ActionView::TestCase
  include Collavre::CreativeMoveHelper

  test "only writable non-archived creatives expose a native move button" do
    creative = Struct.new(:id, :archived?).new(42, false)
    assert_empty render_creative_move_action(creative, false)
    html = render_creative_move_action(creative, true)
    assert_includes html, 'type="button"'
    assert_includes html, 'data-creative-move-id="42"'
    assert_includes html, 'aria-haspopup="dialog"'
    creative[:archived?] = true
    assert_empty render_creative_move_action(creative, true)
  end
end
