require_relative "../application_system_test_case"

class CreativeDeleteMenuSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "delete-menu@example.com", password: SystemHelpers::PASSWORD,
      name: "Delete Menu User", email_verified_at: Time.current,
      notifications_enabled: false, creative_workspace_enabled: true)
    @parent = Creative.create!(user: @user, description: "Delete menu parent")
    @creative = Creative.create!(user: @user, parent: @parent, description: "Delete menu target")
    @child = Creative.create!(user: @user, parent: @creative, description: "Preserved child")
    sign_in_via_ui(@user)
  end

  test "cancel preserves the creative and confirm deletes it then navigates to its parent" do
    visit collavre.creatives_path(id: @creative.id)
    open_delete_menu
    assert_selector "dialog[role='alertdialog'] .confirm-dialog-message",
      text: I18n.t("collavre.creatives.index.are_you_sure_delete_only_this")
    find("dialog[role='alertdialog'] .modal-dialog-btn-secondary").click
    assert_no_selector "dialog[role='alertdialog']"
    assert Creative.exists?(@creative.id)

    open_delete_menu
    find("dialog[role='alertdialog'] .modal-dialog-btn-danger").click

    assert_current_path collavre.creatives_path(id: @parent.id)
    assert_selector "#creative-#{@child.id}"
    assert_not Creative.exists?(@creative.id)
    assert_equal @parent, @child.reload.parent
  end

  private

  def open_delete_menu
    find('[aria-controls="creative-overflow-menu"]').click
    find("#delete-current-creative-btn").click
  end
end
