require "test_helper"

class PermissionCacheConfigTest < ActiveSupport::TestCase
  setup do
    # Store original config value
    @original_config = Rails.application.config.permission_cache_expires_in
    @original_env = ENV["PERMISSION_CACHE_EXPIRES_IN"]
  end

  teardown do
    # Restore original environment and config
    if @original_env
      ENV["PERMISSION_CACHE_EXPIRES_IN"] = @original_env
    else
      ENV.delete("PERMISSION_CACHE_EXPIRES_IN")
    end
    Rails.application.config.permission_cache_expires_in = @original_config
  end

  test "default cache expiry is 7 days" do
    # Ensure no environment variable is set for this test
    ENV.delete("PERMISSION_CACHE_EXPIRES_IN")

    # Reload the configuration to ensure clean state
    load Rails.root.join("config/initializers/permission_cache.rb")

    # Without environment variable, default should be 7 days
    assert_equal 7.days, Rails.application.config.permission_cache_expires_in
  end

  test "cache expiry configuration logic works with different formats safely" do
    # Test the safe parsing logic directly

    # Helper method that mirrors the initializer logic
    def parse_duration(value)
      case value
      when /\A(\d+)\.days?\z/
        $1.to_i.days
      when /\A(\d+)\.hours?\z/
        $1.to_i.hours
      when /\A(\d+)\.minutes?\z/
        $1.to_i.minutes
      when /\A(\d+)\z/
        $1.to_i.seconds
      else
        7.days
      end
    end

    # Test that the parsing logic handles different formats safely
    assert_equal 3.days, parse_duration("3.days")
    assert_equal 3.days, parse_duration("3.day")  # Singular form
    assert_equal 12.hours, parse_duration("12.hours")
    assert_equal 12.hours, parse_duration("12.hour")  # Singular form
    assert_equal 30.minutes, parse_duration("30.minutes")
    assert_equal 30.minutes, parse_duration("30.minute")  # Singular form
    assert_equal 3600.seconds, parse_duration("3600")

    # Test invalid formats return default
    assert_equal 7.days, parse_duration("invalid")
    assert_equal 7.days, parse_duration("system('rm -rf /')")  # Security test
    assert_equal 7.days, parse_duration("eval('1+1')")        # Security test
  end

  test "configuration safely handles malicious environment variables" do
    # Test that malicious input is safely handled without code execution
    malicious_inputs = [
      "system('rm -rf /')",
      "eval('puts \"PWNED\"')",
      "`ls -la`",
      "require 'fileutils'; FileUtils.rm_rf('/')",
      "3.days; system('echo pwned')",
      "#{Time.now}",
      "3.days + system('echo test')",
      "File.delete('important_file')",
      "puts 'executed code'",
      "invalid_format",
      "3.weeks",  # Unsupported format
      "1.year"    # Unsupported format
    ]

    malicious_inputs.each do |malicious_input|
      ENV["PERMISSION_CACHE_EXPIRES_IN"] = malicious_input

      # Reload configuration
      load Rails.root.join("config/initializers/permission_cache.rb")

      # Should default to 7 days for any invalid/malicious input
      assert_equal 7.days, Rails.application.config.permission_cache_expires_in,
                   "Failed to safely handle malicious input: #{malicious_input}"
    end
  end

  test "configuration works with valid environment variable formats" do
    valid_inputs = {
      "3.days" => 3.days,
      "12.hours" => 12.hours,
      "30.minutes" => 30.minutes,
      "3600" => 3600.seconds,
      "1.day" => 1.day,
      "1.hour" => 1.hour,
      "1.minute" => 1.minute
    }

    valid_inputs.each do |input, expected|
      ENV["PERMISSION_CACHE_EXPIRES_IN"] = input

      # Reload configuration
      load Rails.root.join("config/initializers/permission_cache.rb")

      assert_equal expected, Rails.application.config.permission_cache_expires_in,
                   "Failed to parse valid input: #{input}"
    end
  end
end
