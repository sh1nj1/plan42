# frozen_string_literal: true

require "test_helper"
require "rake"

class TestAllTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("test:all")
    @original_test = ENV["TEST"]
  end

  teardown do
    ENV["TEST"] = @original_test
    Rake::Task["test:all"].reenable
  end

  test "returns no requested paths when TEST is empty" do
    ENV.delete("TEST")

    assert_nil TestAllTask.requested_test_paths
  end

  test "parses shell-escaped requested test paths" do
    ENV["TEST"] = "test/models/user_test.rb 'test/lib/path with spaces_test.rb'"

    assert_equal(
      [ "test/models/user_test.rb", "test/lib/path with spaces_test.rb" ],
      TestAllTask.requested_test_paths
    )
  end

  test "passes requested paths as separate process arguments" do
    arguments = nil

    TestAllTask.stub(:system, ->(*values) { arguments = values; true }) do
      assert TestAllTask.run_tests([ "test/models/user_test.rb", "test/lib/path with spaces_test.rb" ])
    end

    assert_equal(
      [ "bin/rails", "test", "test/models/user_test.rb", "test/lib/path with spaces_test.rb" ],
      arguments
    )
  end

  test "test all task runs only requested paths" do
    ENV["TEST"] = "test/models/user_test.rb test/lib/token_test.rb"
    requested_paths = nil

    TestAllTask.stub(:run_tests, ->(paths) { requested_paths = paths; true }) do
      capture_io { Rake::Task["test:all"].invoke }
    end

    assert_equal [ "test/models/user_test.rb", "test/lib/token_test.rb" ], requested_paths
  end
end
