require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class KamalPostDeployHookTest < ActiveSupport::TestCase
  test "reprovisions webhooks when post-deploy omits KAMAL_COMMAND" do
    Dir.mktmpdir do |directory|
      FileUtils.mkdir_p("#{directory}/.kamal/hooks")
      FileUtils.mkdir_p("#{directory}/bin")
      FileUtils.cp(Rails.root.join(".kamal/hooks/post-deploy"), "#{directory}/.kamal/hooks/post-deploy")
      File.write(
        "#{directory}/bin/kamal",
        <<~SH
          #!/bin/sh
          printf '%s\n' "$@" > kamal-arguments
        SH
      )
      FileUtils.chmod("+x", "#{directory}/bin/kamal")

      _stdout, stderr, status = Open3.capture3(
        { "KAMAL_COMMAND" => nil },
        "#{directory}/.kamal/hooks/post-deploy",
        chdir: directory
      )

      assert status.success?, stderr
      arguments = File.readlines("#{directory}/kamal-arguments", chomp: true)
      assert_equal [ "app", "exec", "--primary", "--reuse" ], arguments.first(4)
      assert_equal(
        "sh -c 'if [ -f script/reprovision_github_webhooks ]; " \
          "then bin/rails runner script/reprovision_github_webhooks; fi'",
        arguments.last
      )
    end
  end
end
