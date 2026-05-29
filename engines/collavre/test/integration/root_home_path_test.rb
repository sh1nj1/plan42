require "test_helper"

class RootHomePathTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    Rails.cache.clear
    SystemSetting.where(key: [ "home_page_path", "home_page_path_authenticated", "creatives_login_required" ]).destroy_all
    Rails.cache.clear
  end

  teardown do
    SystemSetting.where(key: [ "home_page_path", "home_page_path_authenticated" ]).destroy_all
    Rails.cache.clear
  end

  test "anonymous visitor to / renders unauthenticated rewrite target without changing URL" do
    SystemSetting.create!(key: "home_page_path", value: "/creatives")
    Rails.cache.clear

    get "/"
    assert_response :success
    # URL stays "/" - the response is rendered from the rewritten path
  end

  test "anonymous visitor to / is unaffected by home_page_path_authenticated" do
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/users")
    Rails.cache.clear

    get "/"
    assert_response :success
    assert_nil response.location
  end

  test "authenticated user hitting / is redirected to home_page_path_authenticated" do
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/users")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    assert_equal "/users", URI.parse(response.location).path
  end

  test "authenticated user hitting / follows redirect even when home_page_path also set" do
    SystemSetting.create!(key: "home_page_path", value: "/creatives")
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/users")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    assert_equal "/users", URI.parse(response.location).path
  end

  test "authenticated user is redirected even when both paths resolve to the same target" do
    SystemSetting.create!(key: "home_page_path", value: "/users")
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/users")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    assert_equal "/users", URI.parse(response.location).path
  end

  test "authenticated user hitting / without setting is redirected to default /creatives" do
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    assert_equal "/creatives", URI.parse(response.location).path
  end

  test "authenticated user falls back to unauth rewrite when admin sets authenticated path to '/'" do
    SystemSetting.create!(key: "home_page_path", value: "/users")
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :success
    # "/" sentinel disables the redirect - middleware rewrite still applies
  end

  test "authenticated user visiting the authenticated home directly does not loop" do
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/users")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/users"

    assert_response :success
    # Direct visit: no root_request flag, no redirect
  end
end
