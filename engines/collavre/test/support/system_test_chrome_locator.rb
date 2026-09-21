require "selenium-webdriver"

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
    path = ENV["CHROMEDRIVER_PATH"] || first_existing([ "/usr/local/bin/chromedriver" ]) || executable_path("chromedriver")
    return path if path && File.file?(path) && File.executable?(path)

    raise Selenium::WebDriver::Error::NoSuchDriverError,
          "Install a trusted chromedriver and set CHROMEDRIVER_PATH or add it to PATH. " \
          "Automatic Selenium Manager downloads are disabled for system tests."
  end

  def chrome_service
    Selenium::WebDriver::Service.chrome(path: chromedriver_path)
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
