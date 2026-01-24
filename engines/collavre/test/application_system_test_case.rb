require "test_helper"
require_relative "support/system_helpers"
require_relative "support/html5_dnd_helpers"
require_relative "support/system_drag_helper"
require "tmpdir"
require "fileutils"
require "securerandom"

module SystemTestChromeLocator
  module_function

  def executable_path(command)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
      candidate = File.join(directory, command)
      return candidate if File.executable?(candidate)
    end

    nil
  end

  def chrome_binary
    ENV["GOOGLE_CHROME_SHIM"] || ENV["CHROME_BIN"] || first_existing([ "/usr/bin/google-chrome-stable", "/usr/bin/google-chrome" ]) || executable_path("chromium-browser") || executable_path("google-chrome-stable") || executable_path("google-chrome")
  end

  def chromedriver_path
    ENV["CHROMEDRIVER_PATH"] || first_existing([ "/usr/local/bin/chromedriver" ]) || executable_path("chromedriver")
  end

  def first_existing(paths)
    paths.find { |path| File.executable?(path) }
  end

  def register_temp_dir(path)
    temp_dirs << path
  end

  def temp_dirs
    @temp_dirs ||= []
  end

  def cleanup_temp_dirs
    temp_dirs.each do |directory|
      FileUtils.remove_entry(directory) if File.exist?(directory)
    end
  end
end

at_exit { SystemTestChromeLocator.cleanup_temp_dirs }

Capybara.register_driver :custom_headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument "--headless"
  options.add_argument "--disable-gpu"
  options.add_argument "--no-sandbox"
  options.add_argument "--disable-dev-shm-usage"
  options.add_argument "--window-size=1920,1080"
  user_data_dir = File.join(Dir.tmpdir, "chrome-profile-#{SecureRandom.uuid}")
  FileUtils.mkdir_p(user_data_dir)
  options.add_argument "--user-data-dir=#{user_data_dir}"
  SystemTestChromeLocator.register_temp_dir(user_data_dir)
  chrome_binary = SystemTestChromeLocator.chrome_binary
  options.binary = chrome_binary if chrome_binary
  driver_path = SystemTestChromeLocator.chromedriver_path
  driver_service = driver_path ? Selenium::WebDriver::Service.chrome(path: driver_path) : nil
  driver_options = { browser: :chrome, options: options }
  driver_options[:service] = driver_service if driver_service

  Capybara::Selenium::Driver.new(app, **driver_options)
end

DRIVER_ENV_KEY = "SYSTEM_TEST_DRIVER".freeze

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include SystemHelpers
  include SystemDragHelper
  include Html5DndHelpers

  driver_name = ENV.fetch(DRIVER_ENV_KEY, "custom_headless_chrome")
  if driver_name == "chrome"
    driven_by :selenium, using: :chrome, screen_size: [ 1920, 1080 ]
  else
    driven_by driver_name.to_sym
  end
end
