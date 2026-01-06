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

  test "should redirect if not admin" do
    sign_in_as(@user, password: "password")
    get admin_path
    assert_redirected_to root_path
  end

  test "should update settings" do
    sign_in_as(@admin, password: "password")
    patch admin_settings_path, params: { help_link: "https://new.example.com" }
    assert_redirected_to admin_path
    assert_equal "https://new.example.com", SystemSetting.help_menu_link
  end
end
