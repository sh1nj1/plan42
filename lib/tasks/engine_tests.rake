namespace :test do
  desc "Run tests for all local engines"
  task :engines do
    if Dir.glob("engines/*/test").any?
      sh "rails test engines/*/test #{ENV['TESTOPTS']}"
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
