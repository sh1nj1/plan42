namespace :test do
  desc "Run tests for all local engines"
  task :engines do
    # Run tests found in engines/*/test. Skip if none exist to avoid error.
    if Dir.glob("engines/*/test").any?
      sh "rails test engines/*/test"
    else
      puts "No engine tests found. Skipping test:engines."
    end
  end
end

if Rake::Task.task_defined?("test")
  Rake::Task["test"].enhance do
    Rake::Task["test:engines"].invoke
  end
end
