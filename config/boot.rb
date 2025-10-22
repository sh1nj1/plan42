ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

env_file = File.expand_path("../.env", __dir__)

if File.file?(env_file)
  File.foreach(env_file) do |line|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    line = line.delete_prefix("export ")
    key, value = line.split("=", 2)
    next if key.nil? || value.nil?

    key = key.strip
    value = value.strip

    if value.start_with?("\"") && value.end_with?("\"")
      value = value[1..-2]
    elsif value.start_with?("'") && value.end_with?("'")
      value = value[1..-2]
    end

    ENV[key] ||= value
  end
end

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
