require "test_helper"

class SystemSettingTest < ActiveSupport::TestCase
  test "help_menu_link helper" do
    assert_equal "https://example.com/one", SystemSetting.help_menu_link

    SystemSetting.destroy_all
    assert_nil SystemSetting.help_menu_link

    SystemSetting.create!(key: "help_menu_link", value: "https://new.example.com")
    assert_equal "https://new.example.com", SystemSetting.help_menu_link
  end

  test "cached_value returns cached result" do
    setting = SystemSetting.create!(key: "test_cache_key", value: "cached_value")

    # First call populates cache
    assert_equal "cached_value", SystemSetting.cached_value("test_cache_key")

    # Direct DB update bypasses callbacks
    setting.update_column(:value, "new_value_direct")

    # Should still return cached value
    assert_equal "cached_value", SystemSetting.cached_value("test_cache_key")

    # Clear cache via callback
    setting.update!(value: "final_value")

    # Now should return updated value
    assert_equal "final_value", SystemSetting.cached_value("test_cache_key")
  end

  test "clear_cache clears old key when key is changed" do
    setting = SystemSetting.create!(key: "old_key", value: "test_value")

    # Populate cache for old key
    assert_equal "test_value", SystemSetting.cached_value("old_key")

    # Change the key (unusual but possible in admin scenarios)
    setting.update!(key: "new_key")

    # Old key cache should be cleared
    # (Without the fix, this would still return "test_value" until TTL)
    assert_nil Rails.cache.read("system_setting:old_key"),
      "Old key's cache entry should be cleared when key is changed"

    # New key should work
    assert_equal "test_value", SystemSetting.cached_value("new_key")
  end

  test "max_login_attempts returns configured value or default" do
    assert_equal SystemSetting::DEFAULT_MAX_LOGIN_ATTEMPTS, SystemSetting.max_login_attempts

    SystemSetting.create!(key: "max_login_attempts", value: "10")
    assert_equal 10, SystemSetting.max_login_attempts
  end

  test "session_timeout_enabled returns false when timeout is 0" do
    assert_not SystemSetting.session_timeout_enabled?

    SystemSetting.create!(key: "session_timeout_minutes", value: "30")
    assert SystemSetting.session_timeout_enabled?
  end

  test "creatives_login_required returns correct value" do
    assert_not SystemSetting.creatives_login_required?

    SystemSetting.create!(key: "creatives_login_required", value: "true")
    assert SystemSetting.creatives_login_required?
  end
end
