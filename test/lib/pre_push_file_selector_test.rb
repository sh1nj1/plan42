# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require Rails.root.join("script/hooks/pre_push_file_selector").to_s

class PrePushFileSelectorTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir
    @selector = PrePushFileSelector.new(root: @directory)
  end

  teardown do
    FileUtils.remove_entry(@directory)
  end

  test "selects only changed Ruby files that still exist" do
    create_files("app/models/user.rb", "lib/tasks/clean.rake", "Gemfile")

    selected = @selector.rubocop_files(
      [ "app/models/user.rb", "app/models/deleted.rb", "app/views/users/show.html.erb", "lib/tasks/clean.rake", "Gemfile" ]
    )

    assert_equal [ "Gemfile", "app/models/user.rb", "lib/tasks/clean.rake" ], selected
  end

  test "maps host source and changed tests to existing related tests" do
    create_files(
      "test/controllers/users_controller_test.rb",
      "test/lib/token_test.rb",
      "test/config/initializers/mail_test.rb",
      "test/models/direct_test.rb"
    )

    selected = @selector.test_files(
      [
        "app/controllers/users_controller.rb",
        "lib/token.rb",
        "config/initializers/mail.rb",
        "app/models/missing.rb",
        "test/models/direct_test.rb"
      ]
    )

    assert_equal(
      [
        "test/config/initializers/mail_test.rb",
        "test/controllers/users_controller_test.rb",
        "test/lib/token_test.rb",
        "test/models/direct_test.rb"
      ],
      selected
    )
  end

  test "maps engine source to tests in the same engine" do
    create_files(
      "engines/collavre/test/models/creative_test.rb",
      "engines/collavre/test/lib/collavre/configuration_test.rb"
    )

    selected = @selector.test_files(
      [
        "engines/collavre/app/models/collavre/creative.rb",
        "engines/collavre/lib/collavre/configuration.rb"
      ]
    )

    assert_equal(
      [
        "engines/collavre/test/lib/collavre/configuration_test.rb",
        "engines/collavre/test/models/creative_test.rb"
      ],
      selected
    )
  end

  test "maps namespaced engine lib source to an unnamespaced test" do
    create_files("engines/collavre_openclaw/test/lib/configuration_test.rb")

    selected = @selector.test_files(
      [ "engines/collavre_openclaw/lib/collavre_openclaw/configuration.rb" ]
    )

    assert_equal [ "engines/collavre_openclaw/test/lib/configuration_test.rb" ], selected
  end

  test "maps changed Rake tasks to task tests" do
    create_files("test/lib/clean_task_test.rb")

    selected = @selector.test_files([ "lib/tasks/clean.rake" ])

    assert_equal [ "test/lib/clean_task_test.rb" ], selected
  end

  private

  def create_files(*paths)
    paths.each do |path|
      full_path = File.join(@directory, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      FileUtils.touch(full_path)
    end
  end
end
