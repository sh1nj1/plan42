require_relative "../application_system_test_case"

class UserTranslationPreferenceSystemTest < ApplicationSystemTestCase
  test "reader can save automatic translation off and on in each locale" do
    user = users(:two)
    user.update!(password: SystemHelpers::PASSWORD, email_verified_at: Time.current)
    sign_in_via_ui(user)

    %w[en ko].each do |locale|
      user.update!(locale: locale)
      visit collavre.user_path(user)
      label = I18n.t("collavre.users.auto_translation_enabled", locale: locale)
      save = I18n.t("collavre.users.update_profile", locale: locale)
      assert_checked_field label
      uncheck label
      click_button save
      assert_selector "#user_auto_translation_enabled:not([checked])"
      refute user.reload.auto_translation_enabled?
      assert_unchecked_field label
      assert_no_selector "html[aria-busy=true]"
      check label
      assert_checked_field label
      click_button save
      assert_selector "#user_auto_translation_enabled[checked]"
      assert user.reload.auto_translation_enabled?
      assert_checked_field label
      assert_no_selector "html[aria-busy=true]"
    end
  end
end
