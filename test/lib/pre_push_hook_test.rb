# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class PrePushHookTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir
    run_command("git", "init", "--quiet")
    run_command("git", "config", "user.email", "test@example.com")
    run_command("git", "config", "user.name", "Test User")

    copy_hook("script/hooks/pre-push")
    copy_hook("script/hooks/pre_push_file_selector.rb")
    create_file("script/check-i18n.rb", "exit 0\n")
    create_file("bin/rubocop", <<~SH, executable: true)
      #!/bin/sh
      printf '%s\\n' "$@" > rubocop-args.txt
    SH
    create_file("sample.rb", "puts :sample # allowed\n")

    run_command("git", "add", ".")
    run_command("git", "commit", "--quiet", "-m", "test fixture")
    @local_sha = run_command("git", "rev-parse", "HEAD").strip
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "falls back to a local base when the remote tip is unavailable" do
    missing_remote_sha = "f" * 40

    stdout, stderr, status = run_hook(
      "refs/heads/topic #{@local_sha} refs/heads/topic #{missing_remote_sha}\n"
    )

    assert status.success?, "#{stdout}\n#{stderr}"
    assert_includes stdout, "Remote tip is unavailable locally"
    assert_includes File.read(File.join(@directory, "rubocop-args.txt")), "sample.rb"
  end

  test "fails when a diff range cannot be resolved" do
    stdout, stderr, status = run_hook(
      "refs/heads/topic #{@local_sha} refs/heads/topic #{"0" * 40}\n",
      "PRE_PUSH_BASE_REF" => "missing-base"
    )

    refute status.success?
    assert_includes "#{stdout}\n#{stderr}", "Unable to determine changed files"
  end

  test "fails when the file selector fails" do
    create_file("script/hooks/pre_push_file_selector.rb", "raise \"selector failure\"\n")

    stdout, stderr, status = run_hook(
      "refs/heads/topic #{@local_sha} refs/heads/topic #{"0" * 40}\n"
    )

    refute status.success?
    assert_includes "#{stdout}\n#{stderr}", "Unable to select changed files for Rubocop"
  end

  test "fails when related test selection fails" do
    create_file("script/hooks/pre_push_file_selector.rb", <<~RUBY)
      exit 0 if ARGV.first == "rubocop"

      raise "test selector failure"
    RUBY

    stdout, stderr, status = run_hook(
      "refs/heads/topic #{@local_sha} refs/heads/topic #{"0" * 40}\n"
    )

    refute status.success?
    assert_includes "#{stdout}\n#{stderr}", "Unable to select related tests"
  end

  private

  def copy_hook(path)
    destination = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp(Rails.root.join(path), destination)
  end

  def create_file(path, contents, executable: false)
    destination = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, contents)
    FileUtils.chmod("u+x", destination) if executable
  end

  def run_command(*command)
    stdout, stderr, status = Open3.capture3(*command, chdir: @directory)
    raise "#{command.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end

  def run_hook(input, environment = {})
    Open3.capture3(
      environment,
      "bash",
      "script/hooks/pre-push",
      "origin",
      stdin_data: input,
      chdir: @directory
    )
  end
end
