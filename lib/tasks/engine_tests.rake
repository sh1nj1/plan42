namespace :test do
  desc "Run tests for all local engines"
  task :engines do
    # Run tests found in engines/*/test
    sh "rails test engines/*/test"
  end
end

if Rake::Task.task_defined?("test")
  Rake::Task["test"].enhance do
    Rake::Task["test:engines"].invoke
  end
end
