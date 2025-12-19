require "test_helper"

module Tools
  class SecurityTest < ActiveSupport::TestCase
    def setup
      @safe_root = Rails.root.join("tmp", "safe_root")
      FileUtils.mkdir_p(@safe_root)
    end

    def teardown
      FileUtils.rm_rf(@safe_root)
    end

    def test_file_service_block_symlink_outside_repo
      secret_file = Rails.root.join("tmp", "secret_file")
      ::File.write(secret_file, "SECRET DATA")

      symlink_path = @safe_root.join("symlink_to_secret")
      FileUtils.ln_s(secret_file, symlink_path)

      service = Tools::FileService.new
      result = service.call(
        action: "read",
        file_path: "symlink_to_secret",
        root_path: @safe_root.to_s
      )

      assert_equal "file", result[:type]
      assert_match /File path must be inside the repository/, result[:error]
    ensure
      FileUtils.rm_f(secret_file)
    end

    def test_git_service_blocks_symlinked_root_outside_rails_root
      symlink_root = Rails.root.join("tmp", "symlink_root")
      FileUtils.rm_f(symlink_root)
      FileUtils.ln_s("/tmp", symlink_root)

      service = Tools::GitService.new

      error = assert_raises(ArgumentError) do
        service.call(
          action: "clone",
          repo: { url: "https://github.com/test/repo" },
          root_path: symlink_root.to_s
        )
      end

      assert_match /root_path must be inside the Rails application root/, error.message
    ensure
      FileUtils.rm_f(symlink_root)
    end
  end
end
