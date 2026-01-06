require "test_helper"

class SystemSettingTest < ActiveSupport::TestCase
  test "help_menu_link helper" do
    assert_equal "https://example.com/one", SystemSetting.help_menu_link

    SystemSetting.destroy_all
    assert_nil SystemSetting.help_menu_link

    SystemSetting.create!(key: "help_menu_link", value: "https://new.example.com")
    assert_equal "https://new.example.com", SystemSetting.help_menu_link
  end
end
