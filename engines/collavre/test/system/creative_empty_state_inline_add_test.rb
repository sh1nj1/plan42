require_relative "../application_system_test_case"

# Regression coverage for Codex review finding on PR #1485
# (engines/collavre/app/views/collavre/creatives/_empty_state.html.erb:65):
# clicking the empty-state's Add button starts the inline "new creative"
# editor but left the big empty-state card visible underneath it, and
# cancelling never brought it back.
class CreativeEmptyStateInlineAddTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "user@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @parent_creative = Creative.create!(description: "Parent", user: @user)

    resize_window_to
    sign_in_via_ui(@user)
    visit collavre.creative_path(@parent_creative)
  end

  test "hides the empty-state card while creating the first sub-creative inline, and restores it on cancel" do
    wait_for_network_idle(timeout: 10)
    assert_selector ".creative-empty-state", visible: true, wait: 5

    find(".creative-empty-state .add-creative-btn", wait: 5).click

    assert_selector "#inline-edit-form-element", wait: 5
    assert_no_selector ".creative-empty-state", visible: true, wait: 5

    find("#inline-close", wait: 5).click
    assert_no_selector ".lexical-content-editable", visible: true, wait: 5
    wait_for_network_idle(timeout: 10)

    assert_selector ".creative-empty-state", visible: true, wait: 5
  end

  # End-to-end coverage for the second Codex finding on this partial: removing
  # the last creative left #creatives holding nothing but the display:none card.
  #
  # These two are flow coverage, NOT discriminating regression tests: with the
  # fix reverted they still pass, because the sync channel repaints the tree
  # (tree_controller#showEmptyState) a moment after the removal and masks the
  # local DOM state. The regression tests that fail without the fix are the
  # Jest ones in creative_row_editor_empty_state_removal.test.js, which drive
  # the real module with the network stubbed out — i.e. the case where that
  # repaint never arrives.
  test "restores the empty-state card after the only sub-creative is deleted" do
    child = create_only_child
    open_inline_editor_on(child)

    find("#inline-delete-popup-toggle", wait: 5).click
    find("#inline-delete", wait: 5).click
    find(".modal-dialog-btn-danger", wait: 5).click

    assert_no_selector row_selector(child), wait: 5
    assert_selector ".creative-empty-state", visible: true, wait: 5
  end

  # Archiving additionally exercises the editor's closeEditor() call, which was
  # an undefined reference until this change and threw inside the .then() rather
  # than closing the editor.
  test "restores the empty-state card after the only sub-creative is archived" do
    child = create_only_child
    open_inline_editor_on(child)

    find("#inline-delete-popup-toggle", wait: 5).click
    find("#inline-archive", wait: 5).click
    find(".modal-dialog-btn-primary", wait: 5).click

    assert_no_selector row_selector(child), wait: 5
    assert_selector ".creative-empty-state", visible: true, wait: 5
  end

  private

  def row_selector(creative)
    "creative-tree-row[dom-id='creative-#{creative.id}']"
  end

  def create_only_child
    child = Creative.create!(description: "Only child", user: @user, parent: @parent_creative)
    visit collavre.creative_path(@parent_creative)
    wait_for_network_idle(timeout: 10)
    assert_selector row_selector(child), wait: 5
    assert_no_selector ".creative-empty-state", visible: true
    child
  end

  # The editor's destructive actions live behind the trash popup menu, which is
  # only reachable once the row is open in the inline editor.
  def open_inline_editor_on(creative)
    find("#{row_selector(creative)} .creative-row", visible: :visible).hover
    within(:css, row_selector(creative)) { find(".edit-inline-btn").click }
    assert_selector "#inline-edit-form-element", visible: :visible, wait: 5
  end
end
