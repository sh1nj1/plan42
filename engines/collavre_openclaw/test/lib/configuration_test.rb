require "test_helper"

module CollavreOpenclaw
  class ConfigurationTest < ActiveSupport::TestCase
    test "has default values" do
      config = Configuration.new
      assert_equal 10, config.open_timeout
      assert_equal 180, config.read_timeout      # 3 minutes for AI responses
      assert_equal 2, config.max_retries
      # Legacy accessor
      assert_equal 180, config.request_timeout
    end

    test "allows setting timeouts" do
      config = Configuration.new
      config.open_timeout = 15
      config.read_timeout = 120
      config.max_retries = 5
      assert_equal 15, config.open_timeout
      assert_equal 120, config.read_timeout
      assert_equal 5, config.max_retries
    end

    test "legacy request_timeout accessor works" do
      config = Configuration.new
      config.request_timeout = 60
      assert_equal 60, config.request_timeout
      assert_equal 60, config.read_timeout  # Should update read_timeout
    end

    test "module configuration block works" do
      original_timeout = CollavreOpenclaw.config.read_timeout

      CollavreOpenclaw.configure do |config|
        config.read_timeout = 45
      end

      assert_equal 45, CollavreOpenclaw.config.read_timeout

      # Restore
      CollavreOpenclaw.config.read_timeout = original_timeout
    end
  end
end
