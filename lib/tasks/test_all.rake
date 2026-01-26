# frozen_string_literal: true

namespace :test do
  # Clear any existing test:all task (Rails 8 may define one)
  Rake::Task["test:all"].clear if Rake::Task.task_defined?("test:all")

  desc "Run all tests (host app + Collavre engine)"
  task all: :environment do
    # Directories that can be run at once (no issues)
    working_dirs = %w[
      test/controllers/admin
      test/controllers/oauth
      test/controllers/webauthn
      test/controllers/github
      engines/collavre/test/assets
      engines/collavre/test/channels
      engines/collavre/test/components
      engines/collavre/test/helpers
      engines/collavre/test/jobs
      engines/collavre/test/lib
      engines/collavre/test/mailers
      engines/collavre/test/models
      engines/collavre/test/services
      engines/collavre/test/controllers
      engines/collavre/test/controllers/comments
      engines/collavre/test/controllers/creatives
    ]

    # Run each working directory
    working_dirs.each do |dir|
      next unless Dir.exist?(dir)
      next if Dir.glob("#{dir}/*_test.rb").empty?

      puts "\n=== Testing #{dir} ==="
      system("bin/rails test #{dir}/") || exit(1)
    end

    # Run integration tests file by file (they have issues with directory mode)
    puts "\n=== Testing engines/collavre/test/integration ==="
    Dir.glob("engines/collavre/test/integration/*_test.rb").sort.each do |file|
      system("bin/rails test #{file}") || exit(1)
    end

    puts "\n=== All tests passed! ==="
  end
end

# Override the default test task to use test:all (excludes system tests)
# Clear the default Rails test task to prevent it from running system tests
Rake::Task["test"].clear if Rake::Task.task_defined?("test")
desc "Run all tests except system tests"
task test: "test:all"
