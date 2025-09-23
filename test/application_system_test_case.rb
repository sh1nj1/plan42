require "test_helper"
require_relative "support/system_helpers"
require "tmpdir"

Capybara.register_driver :custom_headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument "--headless"
  options.add_argument "--disable-gpu"
  options.add_argument "--no-sandbox"
  options.add_argument "--disable-dev-shm-usage"
  options.add_argument "--window-size=1920,1080"
  options.add_argument "--user-data-dir=#{Dir.mktmpdir("chrome-profile-#{Process.pid}-")}"

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemHelpers

  # for local development test with chrome
  # driven_by :selenium, using: :chrome, screen_size: [ 1920, 1080 ]
  driven_by :custom_headless_chrome
end
