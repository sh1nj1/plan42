require "test_helper"

class RootHomePathTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(last_visited_creative_id: nil)
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

  test "authenticated user hitting / returns to their last visited creative" do
    creative = creatives(:tshirt)
    @user.update!(last_visited_creative: creative)

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "/creatives", location.path
    assert_equal creative.id.to_s, Rack::Utils.parse_nested_query(location.query)["id"]
  end

  test "authenticated user returns to their last visited creative when the home path has a trailing slash" do
    creative = creatives(:tshirt)
    @user.update!(last_visited_creative: creative)
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/creatives/")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "/creatives", location.path
    assert_equal creative.id.to_s, Rack::Utils.parse_nested_query(location.query)["id"]
  end

  test "authenticated user returns to their last visited creative when the home path uses the HTML format" do
    creative = creatives(:tshirt)
    @user.update!(last_visited_creative: creative)
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/creatives.html")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/"

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "/creatives", location.path
    assert_equal creative.id.to_s, Rack::Utils.parse_nested_query(location.query)["id"]
  end

  test "authenticated user redirect preserves the engine mount prefix" do
    creative = creatives(:tshirt)
    @user.update!(last_visited_creative: creative)

    sign_in_as(@user, password: "password")
    get "/", env: { "SCRIPT_NAME" => "/collavre" }

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "/collavre/creatives", location.path
    assert_equal creative.id.to_s, Rack::Utils.parse_nested_query(location.query)["id"]
  end

  test "authenticated user returns to their last visited creative with a mounted Creative home path" do
    creative = creatives(:tshirt)
    @user.update!(last_visited_creative: creative)
    SystemSetting.create!(key: "home_page_path_authenticated", value: "/collavre/creatives")
    Rails.cache.clear

    sign_in_as(@user, password: "password")
    get "/", env: { "SCRIPT_NAME" => "/collavre" }

    assert_response :redirect
    location = URI.parse(response.location)
    assert_equal "/collavre/creatives", location.path
    assert_equal creative.id.to_s, Rack::Utils.parse_nested_query(location.query)["id"]
  end

  test "authenticated user cannot be redirected to a creative they no longer can read" do
    private_creative = Collavre::Creative.create!(user: users(:two), description: "Private")
    @user.update!(last_visited_creative: private_creative)

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
