# frozen_string_literal: true

require "test_helper"
require "rake"

class TestAllTaskTest < ActiveSupport::TestCase
  ISOLATED_PATH = "engines/collavre/test/integration/engine_override_test.rb"

  setup do
    @original_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load Rails.root.join("lib/tasks/test_all.rake")
    @task = Rake::Task["test:all"]
    @context = @task.actions.first.binding.receiver
    @commands = []
  end

  teardown do
    Rake.application = @original_rake
  end

  test "runs every non-system test once and isolates the serial executor" do
    run_task

    assert_equal 2, @commands.size
    assert_equal [ "bin/rails", "test", ISOLATED_PATH ], @commands.last
    paths = @commands.flat_map { |command| command.drop(2) }
    expected = Dir.glob("{test,engines/*/test}/**/*_test.rb").reject { |path| path.include?("/system/") }
    assert_equal expected.sort, paths.sort
    assert_equal paths.uniq, paths
    refute_includes @commands.first, ISOLATED_PATH
  end

  test "excluding the core engine also excludes its isolated tests" do
    run_task(excluded: [ "collavre" ])

    assert_equal 1, @commands.size
    refute @commands.first.any? { |path| path.start_with?("engines/collavre/") }
  end

  test "a failed parallel suite stops before running isolated tests" do
    error = assert_raises(SystemExit) { run_task(success: false) }

    assert_equal 1, error.status
    assert_equal 1, @commands.size
  end

  test "a failed isolated suite fails the task" do
    error = assert_raises(SystemExit) { run_task(success: -> { @commands.size == 1 }) }

    assert_equal 1, error.status
    assert_equal 2, @commands.size
  end

  test "an empty selection does not launch a runner" do
    @context.stub(:filter_engine_roots, []) { run_task }

    assert_empty @commands
  end

  test "an isolated-only selection does not launch an empty parallel runner" do
    Dir.stub(:glob, ->(pattern) { pattern == "test/*_test.rb" ? [ ISOLATED_PATH ] : [] }) do
      run_task
    end

    assert_equal [ [ "bin/rails", "test", ISOLATED_PATH ] ], @commands
  end

  private

  def run_task(excluded: [], success: true)
    runner = lambda do |*command|
      @commands << command
      success.respond_to?(:call) ? success.call : success
    end
    @context.stub(:excluded_engines, excluded) do
      @context.stub(:system, runner) { capture_io { @task.invoke } }
    end
  end
end
