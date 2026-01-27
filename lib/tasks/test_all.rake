# frozen_string_literal: true

namespace :test do
  # Clear existing tasks to avoid conflicts/duplication
  Rake::Task["test:all"].clear if Rake::Task.task_defined?("test:all")
  Rake::Task["test:system"].clear if Rake::Task.task_defined?("test:system")

  desc "Run all tests (host app + engines) excluding system tests"
  task all: :environment do
    test_roots = [ "test" ] + Dir.glob("engines/*/test")
    test_paths = []

    test_roots.each do |root|
      next unless Dir.exist?(root)

      # Add top-level test files (e.g. test/foo_test.rb)
      test_paths.concat(Dir.glob("#{root}/*_test.rb"))

      # Add subdirectories, excluding 'system'
      Dir.glob("#{root}/*").each do |path|
        next unless File.directory?(path)
        next if File.basename(path) == "system"

        test_paths << path
      end
    end

    if test_paths.any?
      puts "\n=== Running tests: #{test_paths.join(' ')} ==="
      # Run all collected paths in a single process
      system("bin/rails test #{test_paths.join(' ')}") || exit(1)
    else
      puts "\n=== No tests found ==="
    end

    puts "\n=== All tests passed! ==="
  end

  desc "Run system tests (host app + engines)"
  task system: :environment do
    test_roots = [ "test" ] + Dir.glob("engines/*/test")
    ran_any = false

    test_roots.each do |dir|
      system_dir = "#{dir}/system"
      next unless Dir.exist?(system_dir)

      # Check if there are actual test files to avoid noise
      next if Dir.glob("#{system_dir}/**/*_test.rb").empty?

      puts "\n=== Testing #{system_dir} ==="
      system("bin/rails test #{system_dir}/") || exit(1)
      ran_any = true
    end

    if ran_any
      puts "\n=== All system tests passed! ==="
    else
      puts "\n=== No system tests found ==="
    end
  end
end

# Override the default test task
Rake::Task["test"].clear if Rake::Task.task_defined?("test")
desc "Run all tests except system tests"
task test: "test:all"
