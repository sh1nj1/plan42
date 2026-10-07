require_relative "../application_system_test_case"

class CreativeDeleteMenuSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "delete-menu@example.com", password: SystemHelpers::PASSWORD,
      name: "Delete Menu User", email_verified_at: Time.current,
      notifications_enabled: false, creative_workspace_enabled: true)
    @parent = Creative.create!(user: @user, description: "Delete menu parent")
    @creative = Creative.create!(user: @user, parent: @parent, description: "Delete menu target")
    @child = Creative.create!(user: @user, parent: @creative, description: "Deleted child")
    sign_in_via_ui(@user)
  end

  test "cancel preserves the creative and confirm deletes it with its children then navigates to its parent" do
    visit collavre.creatives_path(id: @creative.id)
    open_delete_menu
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.creatives.index.are_you_sure_delete_with_children")
    find("dialog[role='alertdialog'] .modal-dialog-btn-secondary").click
    assert_no_selector "dialog[role='alertdialog']"
    assert Creative.exists?(@creative.id)

    open_delete_menu
    find("dialog[role='alertdialog'] .modal-dialog-btn-danger").click

    assert_current_path collavre.creatives_path(id: @parent.id)
    assert_no_selector "#creative-#{@child.id}"
    assert_not Creative.exists?(@creative.id)
    assert_not Creative.exists?(@child.id)
  end

  test "a public read link can be removed through the menu while preserving the original" do
    owner = User.create!(email: "link-origin@example.com", password: SystemHelpers::PASSWORD,
      name: "Origin Owner", email_verified_at: Time.current)
    origin = Creative.create!(user: owner, description: "Shared original")
    child = Creative.create!(user: owner, parent: origin, description: "Original child")
    CreativeShare.create!(creative: origin, permission: :read)
    link = Creative.create!(user: @user, parent: @parent, origin: origin)

    visit collavre.creatives_path(id: link.id)
    find('[aria-controls="creative-overflow-menu"]').click
    assert_selector "#delete-current-creative-btn", text: I18n.t("collavre.creatives.index.remove_link")
    find("#delete-current-creative-btn").click
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.creatives.index.are_you_sure_remove_link")
    find("dialog[role='alertdialog'] .modal-dialog-btn-danger").click

    assert_current_path collavre.creatives_path(id: @parent.id)
    assert_not Creative.exists?(link.id)
    assert Creative.exists?(origin.id)
    assert_equal origin.id, child.reload.parent_id
  end

  private

  def open_delete_menu
    find('[aria-controls="creative-overflow-menu"]').click
    find("#delete-current-creative-btn").click
  end
end
