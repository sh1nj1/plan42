require_relative "../../../collavre/test/application_system_test_case"

class UserTranslationPreferenceSystemTest < ApplicationSystemTestCase
  test "reader can save automatic translation off and on in each locale" do
    user = users(:two)
    user.update!(password: SystemHelpers::PASSWORD, email_verified_at: Time.current)
    sign_in_via_ui(user)

    %w[en ko].each do |locale|
      user.update!(locale: locale)
      visit collavre.user_path(user)
      label = I18n.t("collavre_translation.preferences.auto_translation_enabled", locale: locale)
      save = I18n.t("collavre.users.update_profile", locale: locale)
      assert_checked_field label
      assert_no_selector "html[aria-busy=true]"
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

  test "Back reloads the reader gate after saving off and on" do
    user = users(:two)
    user.update!(password: SystemHelpers::PASSWORD, email_verified_at: Time.current)
    CollavreTranslation.model = "test-model"
    sign_in_via_ui(user)

    [ false, true ].each do |enabled|
      visit collavre.creatives_path
      assert_selector "[data-controller=comment-translation-reader]", visible: :all if !enabled
      page.execute_script("document.body.dataset.staleTranslationSnapshot = 'true'")
      page.execute_script("Turbo.visit(arguments[0])", collavre.user_path(user))
      assert_selector "#user_auto_translation_enabled"
      assert_no_selector "html[aria-busy=true]"
      assert_no_selector "body[data-stale-translation-snapshot]"
      find("#user_auto_translation_enabled").set(enabled)
      click_button I18n.t("collavre.users.update_profile", locale: user.locale)
      if enabled
        assert_selector "#user_auto_translation_enabled[checked]"
      else
        assert_selector "#user_auto_translation_enabled:not([checked])"
      end
      assert_equal enabled, user.reload.auto_translation_enabled?
      assert_no_selector "html[aria-busy=true]"
      page.go_back
      assert_current_path collavre.creatives_path
      assert_no_selector "body[data-stale-translation-snapshot]"
      assert_selector "[data-controller=comment-translation-reader]", visible: :all
      assert_selector "[data-controller=creative-translations]", visible: :all
      assert_selector "#creative-overflow-menu .creative-translation-toggle", visible: :all
    end
  ensure
    CollavreTranslation.model = nil
  end
end
