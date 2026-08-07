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
end
