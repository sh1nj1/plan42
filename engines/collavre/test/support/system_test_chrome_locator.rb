require "selenium-webdriver"
require_relative "system_test_chrome_installation"

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
    return SystemTestChromeInstallation.paths.first unless explicit_configuration?

    ENV["GOOGLE_CHROME_SHIM"] || ENV["CHROME_BIN"] || %w[/usr/bin/google-chrome-stable /usr/bin/google-chrome].find { |path| File.executable?(path) } ||
      executable_path("chromium-browser") || executable_path("google-chrome-stable") || executable_path("google-chrome")
  end

  def chromedriver_path
    return SystemTestChromeInstallation.paths.last unless explicit_configuration?

    path = ENV["CHROMEDRIVER_PATH"]
    return path if path && File.file?(path) && File.executable?(path)

    raise Selenium::WebDriver::Error::NoSuchDriverError,
          "Set CHROMEDRIVER_PATH to a compatible executable when configuring a custom browser or driver."
  end

  def chrome_service
    Selenium::WebDriver::Service.chrome(path: chromedriver_path)
  end

  def explicit_configuration?
    %w[CHROME_BIN GOOGLE_CHROME_SHIM CHROMEDRIVER_PATH].any? { |key| ENV.key?(key) }
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
