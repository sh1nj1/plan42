require "test_helper"
require_relative "../../../app/controllers/admin/settings_controller"

class AdminSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:one)
    @user = users(:two)
  end

  test "should get index if admin" do
    sign_in_as(@admin, password: "password")
    get admin_path
    assert_response :success
  end

  test "should return 404 if not admin" do
    sign_in_as(@user, password: "password")
    get admin_path
    assert_response :not_found
  end

  test "should update settings" do
    sign_in_as(@admin, password: "password")
    patch admin_settings_path, params: { help_link: "https://new.example.com", auth_providers: [ "email" ] }
    assert_redirected_to admin_path
    assert_equal "https://new.example.com", SystemSetting.help_menu_link
  end

  test "password_min_length is clamped to floor of 8" do
    sign_in_as(@admin, password: "password")

    patch admin_settings_path, params: { password_min_length: 1, auth_providers: [ "email" ] }

    assert_redirected_to admin_path
    Rails.cache.clear
    assert_equal SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH, SystemSetting.password_min_length,
      "password_min_length should be clamped to floor of #{SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH}"
  end

  test "password_min_length is clamped to ceiling of 72" do
    sign_in_as(@admin, password: "password")

    patch admin_settings_path, params: { password_min_length: 100, auth_providers: [ "email" ] }

    assert_redirected_to admin_path
    Rails.cache.clear
    assert_equal 72, SystemSetting.password_min_length,
      "password_min_length should be clamped to ceiling of 72"
  end

  test "password_min_length accepts valid value within range" do
    sign_in_as(@admin, password: "password")

    patch admin_settings_path, params: { password_min_length: 15, auth_providers: [ "email" ] }

    assert_redirected_to admin_path
    Rails.cache.clear
    assert_equal 15, SystemSetting.password_min_length
  end

  test "password_min_length form field has correct min attribute" do
    sign_in_as(@admin, password: "password")

    get admin_path

    assert_response :success
    assert_select "input[name='password_min_length'][min='#{SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH}'][max='72']"
  end
end
