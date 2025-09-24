require "test_helper"
require_relative "support/system_helpers"
require "tmpdir"
require "fileutils"

Capybara.register_driver :custom_headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument "--headless"
  options.add_argument "--disable-gpu"
  options.add_argument "--no-sandbox"
  options.add_argument "--disable-dev-shm-usage"
  options.add_argument "--window-size=1920,1080"
  user_data_dir = Dir.mktmpdir("chrome-profile-#{Process.pid}-")
  options.add_argument "--user-data-dir=#{user_data_dir}"
  at_exit do
    FileUtils.remove_entry(user_data_dir) if File.exist?(user_data_dir)
  end

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

DRIVER_ENV_KEY = "SYSTEM_TEST_DRIVER".freeze

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemHelpers

  driver_name = ENV.fetch(DRIVER_ENV_KEY, "custom_headless_chrome")
  if driver_name == "chrome"
    driven_by :selenium, using: :chrome, screen_size: [ 1920, 1080 ]
  else
    driven_by driver_name.to_sym
  end
end
