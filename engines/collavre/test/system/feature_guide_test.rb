require_relative "../application_system_test_case"

# The guide pages render inside the landing layout, whose stylesheet used to hide
# every <nav> on the page. A response-body assertion cannot catch that — the
# breadcrumb markup is present either way — so visibility is asserted in a real
# browser instead.
class FeatureGuideTest < ApplicationSystemTestCase
  test "the default help link opens the complete feature guide in the current window" do
    registry = Navigation::Registry.instance
    original_help_item = registry.find(:help)
    registry.register(
      key: :help,
      label: "app.help",
      type: :partial,
      partial: "collavre/shared/navigation/help_button",
      priority: 170
    )
    SystemSetting.find_by(key: "help_menu_link")&.destroy
    visit root_path
    app_path = page.current_path
    windows_before = page.windows.size

    find("a#creative-guide-link", visible: :visible, match: :first).click

    assert_current_path collavre.features_path(locale: I18n.locale)
    assert_equal windows_before, page.windows.size, "the help link must not open a new window"
    assert_selector ".feature-guide-link-card", count: 9

    find("a[href^='/features/mention_agent']").click

    assert_selector "h1", text: I18n.t("collavre.features.pages.mention_agent.title")

    # The whole point of staying in this window: back walks straight into the app.
    page.go_back
    page.go_back

    assert_current_path app_path
  ensure
    original_help_item ? registry.register(original_help_item) : registry.unregister(:help)
  end

  test "the hub breadcrumb is visible" do
    visit collavre.features_path

    assert_selector "nav.feature-guide-breadcrumb"
    assert_link I18n.t("collavre.features.nav.landing")
  end

  test "a guide breadcrumb is visible and walks back to the hub" do
    visit collavre.feature_path(:mention_agent)

    assert_selector "nav.feature-guide-breadcrumb"
    assert_link I18n.t("collavre.features.nav.landing")

    click_link I18n.t("collavre.features.nav.all")

    assert_selector "h1", text: I18n.t("collavre.features.index.title")
  end

  # The landing layout carries no application navigation, and the desktop shell's
  # single webview has no back button, so the breadcrumb's return link is a
  # signed-in reader's only visible way out of the guide.
  test "a signed-in reader can return to the app from the guide" do
    user = User.create!(
      email: "guide-reader@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Guide Reader",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    sign_in_via_ui(user)
    app_path = page.current_path

    visit collavre.feature_path(:mention_agent)

    assert_selector "a.feature-guide-back-to-app", visible: :visible
    click_link I18n.t("collavre.features.nav.back_to_app", app_name: I18n.t("app.name"))

    assert_current_path app_path
  end

  test "a hub card opens its guide" do
    visit collavre.features_path

    assert_text I18n.t("collavre.features.index.card_more")
    find("a[href^='/features/mention_agent']").click

    assert_selector "h1", text: I18n.t("collavre.features.pages.mention_agent.title")
  end
end
