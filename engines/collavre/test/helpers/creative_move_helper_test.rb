require "test_helper"

class CreativeMoveHelperTest < ActionView::TestCase
  include Collavre::CreativeMoveHelper

  test "only writable non-archived creatives expose a native move button" do
    creative = Struct.new(:id, :archived?, :creative_snippet).new(42, false, "Quarterly plan")
    assert_empty render_creative_move_action(creative, false)
    html = render_creative_move_action(creative, true)
    assert_includes html, 'type="button"'
    assert_includes html, 'data-creative-move-id="42"'
    assert_includes html, 'aria-haspopup="dialog"'
    creative[:archived?] = true
    assert_empty render_creative_move_action(creative, true)
  end

  # Every row renders this button, so the visible label alone leaves a screen
  # reader with a list of controls it cannot tell apart.
  test "the accessible name names the creative rather than repeating the visible label" do
    creative = Struct.new(:id, :archived?, :creative_snippet).new(42, false, "Quarterly plan")
    html = render_creative_move_action(creative, true)

    assert_includes html, I18n.t("collavre.dnd.move_creative", title: "Quarterly plan")
    assert_not_equal I18n.t("collavre.dnd.move_title"),
      Nokogiri::HTML5.fragment(html).at_css("button")["aria-label"]
  end

  test "both locales interpolate the creative into the accessible name" do
    %w[en ko].each do |locale|
      name = I18n.t("collavre.dnd.move_creative", title: "Quarterly plan", locale: locale)
      assert_includes name, "Quarterly plan", "#{locale} must name the creative"
      assert_not_includes name, "%{title}", "#{locale} must interpolate the title"
    end
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
