require "test_helper"

class CreativeMoveHelperTest < ActionView::TestCase
  include Collavre::CreativeMoveHelper

  # The launcher is only rendered for a signed-in viewer, so every case below
  # that expects markup has to run with a session.
  setup do
    Collavre::Current.user = users(:one)
  end

  teardown do
    Collavre::Current.user = nil
  end

  test "readable creatives expose the menu while write permission controls the move option" do
    creative = Struct.new(:id, :archived?, :creative_snippet).new(42, false, "Quarterly plan")
    read_only_html = render_creative_move_action(creative, false)
    assert_includes read_only_html, 'data-creative-move-id="42"'
    assert_includes read_only_html, 'data-creative-move-writable="false"'
    html = render_creative_move_action(creative, true)
    assert_includes html, 'type="button"'
    assert_includes html, 'data-creative-move-id="42"'
    assert_includes html, 'aria-haspopup="dialog"'
    assert_includes html, 'data-creative-move-writable="true"'
  end

  test "archived parents expose selection without using the parent as a source" do
    creative = Struct.new(:id, :archived?).new(42, true)
    html = render_creative_move_action(creative, true)
    assert_includes html, 'data-creative-move-id=""'
    assert_not_includes html, 'data-creative-move-id="42"'
    Collavre::Current.user = nil
    assert_empty render_creative_move_action(creative, true)
  end

  # index/show allow unauthenticated access when creatives_login_required? is
  # off, so a public creative renders rows for visitors with no session. Move is
  # unavailable to them and so is the link fallback, because link_drop is not an
  # unauthenticated action -- the menu could only send them to sign-in.
  test "signed-out visitors get no move launcher" do
    creative = Struct.new(:id, :archived?, :creative_snippet).new(42, false, "Quarterly plan")

    Collavre::Current.user = nil

    assert_empty render_creative_move_action(creative, false)
    assert_empty render_creative_move_action(creative, true)
  end

  # The root route renders the header without a current creative. There is
  # nothing for the action to move there, so it is not offered at all.
  test "the root menu has no move action without a current creative" do
    assert_empty render_creative_move_action(nil, nil)
  end

  # The action is named by its visible label alone now that a page renders one
  # of it, so that label is the whole accessible name in both locales.
  test "both locales label the action" do
    creative = Struct.new(:id, :archived?).new(42, false)

    %w[en ko].each do |locale|
      I18n.with_locale(locale) do
        assert_includes render_creative_move_action(creative, true),
          I18n.t("collavre.dnd.move_title", locale: locale)
      end
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
