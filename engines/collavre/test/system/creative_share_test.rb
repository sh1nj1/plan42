require_relative "../application_system_test_case"

class CreativeShareSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "user1@example.com",
      password: SystemHelpers::PASSWORD,
      name: "User1",
      email_verified_at: Time.current
    )
    @creative = Creative.create!(description: "테스트", user: @user)
    CreativeShare.create!(creative: @creative, user: @user, permission: :read)
  end

  test "shows share list" do
    resize_window_to

    visit collavre.new_session_path
    assert_no_field placeholder: I18n.t("collavre.users.new.enter_your_name")
    fill_in placeholder: I18n.t("collavre.users.new.enter_your_email"), with: @user.email
    fill_in placeholder: I18n.t("collavre.users.new.enter_your_password"), with: SystemHelpers::PASSWORD
    find("#sign-in-submit").click
    assert_current_path root_path

    visit collavre.creative_path(@creative)

    assert_selector "#share-creative-modal", text: I18n.t("collavre.creatives.index.shared_with"), visible: :all
    assert_selector "#share-creative-modal", text: "User1", visible: :all
    assert_selector "#share-creative-modal", text: "Read", visible: :all
  end
end
