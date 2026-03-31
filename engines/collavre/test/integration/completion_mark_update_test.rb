require "test_helper"

class CompletionMarkUpdateTest < ActionDispatch::IntegrationTest
  test "admin can update completion mark via admin settings" do
    admin = users(:one) # system_admin: true
    admin.update!(email_verified_at: Time.current)
    post session_path, params: { email: admin.email, password: "password" }
    assert_response :redirect

    patch collavre.admin_uiux_path, params: {
      completion_mark: "✓",
      display_level: 6,
      default_light_theme_id: "",
      default_dark_theme_id: ""
    }
    assert_redirected_to collavre.admin_uiux_path

    Rails.cache.delete("system_setting:completion_mark")
    assert_equal "✓", Collavre::SystemSetting.completion_mark
  end

  test "admin can update display level via admin settings" do
    admin = users(:one) # system_admin: true
    admin.update!(email_verified_at: Time.current)
    post session_path, params: { email: admin.email, password: "password" }
    assert_response :redirect

    patch collavre.admin_uiux_path, params: {
      completion_mark: "",
      display_level: 10,
      default_light_theme_id: "",
      default_dark_theme_id: ""
    }
    assert_redirected_to collavre.admin_uiux_path

    Rails.cache.delete("system_setting:display_level")
    assert_equal 10, Collavre::SystemSetting.display_level
  end
end
