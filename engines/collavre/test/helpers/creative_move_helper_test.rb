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

# The engine is isolated, so its helpers are not on the host's helpers_path.
# A row part living in its own module is only reachable from a real request if
# something on the CreativesHelper chain pulls it in — miss that and every
# render_creative_progress call site raises NoMethodError at runtime.
class CreativeMoveHelperReachabilityTest < ActiveSupport::TestCase
  test "the view context that renders creative rows exposes the move action" do
    view = Collavre::CreativesController.new.view_context
    assert_respond_to view, :render_creative_progress
    assert_respond_to view, :render_creative_move_action
  end
end
