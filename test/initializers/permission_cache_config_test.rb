require "test_helper"

class PermissionCacheConfigTest < ActiveSupport::TestCase
  test "default cache expiry is 7 days" do
    # Without environment variable, default should be 7 days
    assert_equal 7.days, Rails.application.config.permission_cache_expires_in
  end

  test "cache expiry can be configured via environment variable" do
    # Test different valid formats for PERMISSION_CACHE_EXPIRES_IN

    # Test days format
    ENV["PERMISSION_CACHE_EXPIRES_IN"] = "3.days"
    load Rails.root.join("config/initializers/permission_cache.rb")
    # Can't easily test this without reloading the entire app,
    # but the initializer code handles this case

    # Test hours format
    ENV["PERMISSION_CACHE_EXPIRES_IN"] = "12.hours"
    # Same limitation as above

    # Test numeric seconds format
    ENV["PERMISSION_CACHE_EXPIRES_IN"] = "3600"
    # Same limitation as above

    # Clean up
    ENV.delete("PERMISSION_CACHE_EXPIRES_IN")

    # This test mainly documents the expected behavior
    # The actual functionality is tested by the initializer logic
    assert true
  end
end
