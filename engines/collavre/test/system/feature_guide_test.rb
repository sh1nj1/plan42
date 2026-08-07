require_relative "../application_system_test_case"

# The guide pages render inside the landing layout, whose stylesheet used to hide
# every <nav> on the page. A response-body assertion cannot catch that — the
# breadcrumb markup is present either way — so visibility is asserted in a real
# browser instead.
class FeatureGuideTest < ApplicationSystemTestCase
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

  test "a hub card opens its guide" do
    visit collavre.features_path

    assert_text I18n.t("collavre.features.index.card_more")
    find("a[href$='/features/mention_agent']").click

    assert_selector "h1", text: I18n.t("collavre.features.pages.mention_agent.title")
  end
end
