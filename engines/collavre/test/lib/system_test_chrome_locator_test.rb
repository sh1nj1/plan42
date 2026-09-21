require "test_helper"
require "tempfile"
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
end
