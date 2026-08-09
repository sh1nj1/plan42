require "test_helper"

# The GNB chat button and the search popup filters only mean something on the
# creative index (Creatives::IndexQuery is the sole consumer of their params),
# so both ship the index path and an "am I already there?" flag to the client.
class CreativeFilterNavigationTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "filter-nav@example.com", password: TEST_PASSWORD, name: "Filter Nav", system_admin: true)
    Rails.cache.clear
    SystemSetting.where(key: [ "home_page_path", "home_page_path_authenticated" ]).destroy_all
    Rails.cache.clear
    sign_in_as(@user)
  end

  teardown do
    SystemSetting.where(key: [ "home_page_path", "home_page_path_authenticated" ]).destroy_all
    Rails.cache.clear
  end

  test "creative index marks both filter controls as already on the index" do
    get creatives_path

    assert_response :success
    assert_select "[data-controller='progress-filter'][data-progress-filter-on-index-value='true']"
    assert_select "[data-controller='search-popup'][data-search-popup-on-index-value='true']"
  end

  # The reason on-index cannot be a JS pathname comparison: with the
  # authenticated home page left at "/", the root route renders
  # creatives#index while the browser URL stays "/" rather than "/creatives".
  test "root route marks the filter controls as on the index despite the different path" do
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/")
    Rails.cache.clear

    get root_path

    assert_response :success
    assert_select "[data-progress-filter-on-index-value='true']"
    assert_select "[data-search-popup-on-index-value='true']"
    assert_select "[data-progress-filter-index-path-value='#{creatives_path}']"
  end

  test "a page outside the creative index marks the filter controls as off-index" do
    get users_path

    assert_response :success
    assert_select "[data-progress-filter-on-index-value='false']"
    assert_select "[data-search-popup-on-index-value='false']"
  end

  test "filter controls carry the creative index path so they can navigate back to it" do
    get users_path

    assert_response :success
    assert_select "[data-progress-filter-index-path-value='#{creatives_path}']"
    assert_select "[data-search-popup-index-path-value='#{creatives_path}']"
  end

  test "search popup filter buttons expose the state keys the client re-derives" do
    get creatives_path

    assert_response :success
    assert_select "[data-filter-state='any-filter']"
    assert_select "[data-filter-state='progress:all']"
    assert_select "[data-filter-state='progress:incomplete']"
    assert_select "[data-filter-state='progress:complete']"
    assert_select "[data-filter-state='comment']"
    assert_select "[data-filter-state='archived'][data-label-on][data-label-off]"
  end

  test "archive button ships both labels so the client can swap them without a round trip" do
    get creatives_path

    assert_response :success
    assert_select "[data-filter-state='archived']" do |elements|
      button = elements.first
      assert_equal I18n.t("collavre.creatives.index.hide_archived"), button["data-label-on"]
      assert_equal I18n.t("collavre.creatives.index.show_archived"), button["data-label-off"]
    end
  end
end
