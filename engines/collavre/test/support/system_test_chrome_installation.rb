require "rbconfig"
require "fileutils"
require "tmpdir"

module SystemTestChromeInstallation
  # Chrome 158 rejects the wildcard origin used by Capybara 3.40 during reset.
  VERSION = File.read(File.join(__dir__, "chrome-version")).strip.freeze
  PLATFORMS = {
    [ "darwin", "arm64" ] => "mac-arm64",
    [ "darwin", "x86_64" ] => "mac-x64",
    [ "linux", "x86_64" ] => "linux64"
  }.freeze

  module_function

  def paths
    @paths ||= install
  end

  def install
    platform = PLATFORMS.fetch([ RbConfig::CONFIG.fetch("host_os")[/\A[a-z]+/], RbConfig::CONFIG.fetch("host_cpu") ]) do
      raise "Chrome for Testing is unavailable on this platform. Set CHROME_BIN and CHROMEDRIVER_PATH to a compatible pair."
    end
    cache_home = ENV.fetch("XDG_CACHE_HOME", "")
    cache_home = File.join(Dir.home, ".cache") if cache_home.empty?
    cache = File.join(cache_home, "collavre", "chrome-for-testing")
    FileUtils.mkdir_p(cache)
    destination = File.join(cache, "#{VERSION}-#{platform}")
    browser = if platform.start_with?("mac-")
      "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
    else
      "chrome"
    end
    binaries = [ "chrome-#{platform}/#{browser}", "chromedriver-#{platform}/chromedriver" ]
    File.open("#{destination}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      unless ready?(destination, binaries)
        Dir.mktmpdir("download-", cache) do |temporary_directory|
          staging = File.join(temporary_directory, "installation")
          FileUtils.mkdir(staging)
          %w[chrome chromedriver].each { |artifact| download(artifact, platform, staging) }
          raise "Chrome for Testing download is missing an executable" unless ready?(staging, binaries)

          FileUtils.rm_rf(destination)
          File.rename(staging, destination)
        end
      end
    end
    binaries.map { |binary| File.join(destination, binary) }
  end

  def ready?(directory, binaries)
    binaries.all? do |binary|
      path = File.join(directory, binary)
      File.file?(path) && File.executable?(path)
    end
  end

  def download(artifact, platform, staging)
    archive = File.join(staging, "#{artifact}.zip")
    url = "https://storage.googleapis.com/chrome-for-testing-public/#{VERSION}/#{platform}/#{artifact}-#{platform}.zip"
    unless system("curl", "--fail", "--silent", "--show-error", "--location", "--retry", "2", "--output", archive, url) &&
        system("unzip", "-q", archive, "-d", staging)
      raise "Could not install Chrome for Testing #{VERSION} (#{artifact}, #{platform})"
    end

    File.delete(archive)
  end
end
