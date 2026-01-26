require_relative "../application_system_test_case"

class UserSignupTest < ApplicationSystemTestCase
  test "user can sign up" do
    visit collavre.new_user_path
    fill_in placeholder: I18n.t("users.new.enter_your_name"), with: "Test User"
    fill_in placeholder: I18n.t("users.new.enter_your_email"), with: "testuser@example.com"
    fill_in placeholder: I18n.t("users.new.enter_your_password"), with: SystemHelpers::PASSWORD
    fill_in placeholder: I18n.t("users.new.confirm_your_password"), with: SystemHelpers::PASSWORD
    click_button I18n.t("users.new.sign_up")

    assert_text I18n.t("users.new.success_sign_up")
    assert User.find_by(email: "testuser@example.com")
  end
end
