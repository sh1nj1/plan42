namespace :test do
  desc "Run tests for all local engines. Use E=engine1,engine2 to exclude engines."
  task :engines do
    excluded = (ENV["E"] || ENV["EXCLUDE"] || "").split(",").map(&:strip).reject(&:empty?)
    engine_paths = Dir.glob("engines/*/test").reject do |path|
      engine_name = path.split("/")[1]
      excluded.include?(engine_name)
    end

    if excluded.any?
      puts "\n=== Excluding engines: #{excluded.join(', ')} ==="
    end

    if engine_paths.any?
      sh "rails test #{engine_paths.join(' ')} #{ENV['TESTOPTS']}"
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
