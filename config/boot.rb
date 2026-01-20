ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.

# Load environment variables from .env files before Rails boots
# This ensures RAILS_MASTER_KEY is available for credentials decryption
require "dotenv"
Dotenv.load(".env.#{ENV.fetch('RAILS_ENV', 'development')}")
