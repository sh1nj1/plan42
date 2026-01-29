ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# Load environment variables from .env files before Rails boots
# This ensures RAILS_MASTER_KEY is available for credentials decryption
require "dotenv"

# Set RAILS_ENV to test if running test command before dotenv loads
# Handles: rails test, rake test, rake test:system, rake test:all, etc.
ENV["RAILS_ENV"] ||= "test" if ARGV.any? { |arg| arg == "test" || arg.start_with?("test:") }

Dotenv.overload(".env.#{ENV.fetch('RAILS_ENV', 'development')}")
