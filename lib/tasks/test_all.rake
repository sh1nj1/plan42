# frozen_string_literal: true

namespace :test do
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

# Make 'test:all' the default test task
task test: "test:all"
