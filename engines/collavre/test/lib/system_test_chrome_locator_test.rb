require "test_helper"
require "tempfile"
require "open3"
require_relative "../support/system_test_chrome_locator"

class SystemTestChromeLocatorTest < ActiveSupport::TestCase
  setup do
    @original_driver = ENV.delete("CHROMEDRIVER_PATH")
  end

  teardown do
    @original_driver ? ENV["CHROMEDRIVER_PATH"] = @original_driver : ENV.delete("CHROMEDRIVER_PATH")
  end

  test "missing driver fails instead of invoking Selenium Manager" do
    SystemTestChromeLocator.stub(:first_existing, nil) do
      SystemTestChromeLocator.stub(:executable_path, nil) do
        Selenium::WebDriver::SeleniumManager.stub(:binary_paths, ->(*) { flunk "Manager must not run" }) do
          error = assert_raises(Selenium::WebDriver::Error::NoSuchDriverError) do
            SystemTestChromeLocator.chrome_service
          end
          assert_includes error.message, "CHROMEDRIVER_PATH"
        end
      end
    end
  end

  test "explicit invalid driver does not fall back to PATH or Manager" do
    ENV["CHROMEDRIVER_PATH"] = "/missing/chromedriver"
    SystemTestChromeLocator.stub(:executable_path, ->(*) { flunk "invalid explicit path must fail" }) do
      assert_raises(Selenium::WebDriver::Error::NoSuchDriverError) do
        SystemTestChromeLocator.chrome_service
      end
    end
  end

  test "non-executable files and directories are rejected" do
    Tempfile.create("driver") do |file|
      ENV["CHROMEDRIVER_PATH"] = file.path
      assert_raises(Selenium::WebDriver::Error::NoSuchDriverError) { SystemTestChromeLocator.chrome_service }
      ENV["CHROMEDRIVER_PATH"] = File.dirname(file.path)
      assert_raises(Selenium::WebDriver::Error::NoSuchDriverError) { SystemTestChromeLocator.chrome_service }
    end
  end

  test "explicit local service bypasses Manager discovery" do
    Tempfile.create("driver") do |file|
      File.chmod(0o700, file.path)
      ENV["CHROMEDRIVER_PATH"] = file.path
      Selenium::WebDriver::SeleniumManager.stub(:binary_paths, ->(*) { flunk "Manager must not run" }) do
        service = SystemTestChromeLocator.chrome_service
        finder = Selenium::WebDriver::DriverFinder.new(Selenium::WebDriver::Chrome::Options.new, service)
        assert_equal file.path, finder.driver_path
        assert_nil finder.browser_path
      end
    end
  end

  test "Rails driver preload never invokes Manager for supported browser modes" do
    Tempfile.create("driver") do |file|
      File.chmod(0o700, file.path)
      script = <<~RUBY
        require "selenium-webdriver"
        Selenium::WebDriver::SeleniumManager.define_singleton_method(:binary_paths) do |*|
          abort "Manager must not run"
        end
        require_relative "engines/collavre/test/application_system_test_case"
        service = Selenium::WebDriver::Chrome::Service.new
        finder = Selenium::WebDriver::DriverFinder.new(Selenium::WebDriver::Chrome::Options.new, service)
        abort "Wrong driver" unless finder.driver_path == ENV.fetch("CHROMEDRIVER_PATH")
      RUBY
      %w[custom_headless_chrome hovering_pointer_headless_chrome chrome].each do |mode|
        output, status = Open3.capture2e(
          { "SYSTEM_TEST_DRIVER" => mode, "CHROMEDRIVER_PATH" => file.path },
          RbConfig.ruby, "-Itest", "-e", script, chdir: Rails.root
        )
        assert status.success?, "#{mode}: #{output}"
      end
    end
  end

  test "unconfigured browser modes fail before Manager can run" do
    script = <<~RUBY
      require "selenium-webdriver"
      Selenium::WebDriver::SeleniumManager.define_singleton_method(:binary_paths) do |*|
        abort "Manager must not run"
      end
      begin
        require_relative "engines/collavre/test/application_system_test_case"
      rescue ArgumentError => error
        abort error.message unless error.message.include?("Unsupported SYSTEM_TEST_DRIVER")
        exit 0
      end
      abort "Unconfigured driver was accepted"
    RUBY
    %w[selenium selenium_headless selenium_chrome_headless].each do |mode|
      output, status = Open3.capture2e(
        { "SYSTEM_TEST_DRIVER" => mode }, RbConfig.ruby, "-Itest", "-e", script, chdir: Rails.root
      )
      assert status.success?, "#{mode}: #{output}"
    end
  end
end
