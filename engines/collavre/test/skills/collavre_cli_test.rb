# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"

class CollavreCliTest < ActiveSupport::TestCase
  test "auth creates and repairs credential paths with owner-only modes" do
    [ false, true ].each do |preexisting|
      Dir.mktmpdir do |home|
        config_dir = File.join(home, ".config", "collavre")
        config_file = File.join(config_dir, "config.json")
        exposed_file = nil
        original_inode = nil
        if preexisting
          FileUtils.mkdir_p(config_dir)
          File.write(config_file, "{}")
          File.chmod(0o755, config_dir)
          File.chmod(0o644, config_file)
          original_inode = File.stat(config_file).ino
          exposed_file = File.open(config_file)
        end

        stdout, stderr, status = run_auth(home)

        assert_predicate status, :success?, stderr
        assert_includes stdout, "Saved config"
        assert_equal 0o700, File.stat(config_dir).mode & 0o777
        assert_equal 0o600, File.stat(config_file).mode & 0o777
        assert_equal({ "url" => "https://collavre.example", "token" => "callback-token" },
          JSON.parse(File.read(config_file)))
        assert_empty Dir.glob(File.join(config_dir, ".config.json.*.tmp"))
        if exposed_file
          assert_not_equal original_inode, File.stat(config_file).ino
          exposed_file.rewind
          assert_equal "{}", exposed_file.read
        end
      ensure
        exposed_file&.close
      end
    end
  end

  private

  def run_auth(home)
    script = Rails.root.join("engines/collavre/skills/collavre/scripts/collavre")
    Open3.capture3(
      { "HOME" => home },
      "sh", "-c", 'umask 022; exec "$@"', "sh",
      "node", script.to_s, "auth",
      "--url", "https://collavre.example",
      "--token", "callback-token"
    )
  end
end
