require_relative "boot"

require "rails/all"
require_relative "../lib/collavre/version"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Ensure .env values override existing ENV values when using dotenv's Rails integration
if defined?(Dotenv::Rails)
  Dotenv::Rails.overwrite = true
end

module Collavre
  class Application < Rails::Application
    # closure_tree uses lock file if db is not MySQL or PostgreSQL. set FLOCK_DIR to tmp dir.
    config.before_initialize do
      ENV["FLOCK_DIR"] = Rails.root.join("tmp").to_s
    end

    # Load environment variables from .env.production if it exists
    env_file = File.expand_path("../../.env.production", __FILE__)
    if ENV["RAILS_ENV"] == "development" && File.exist?(env_file)
      # Read .env.production and extract variable names
      env_vars = File.readlines(env_file)
                     .reject { |line| line.strip.empty? || line.start_with?("#") }
                     .map { |line| line.split("=").first.strip }
      # Only show environment variables that are defined in .env.production
      ENV.each do |key, value|
        next unless env_vars.include?(key)
        puts "#{key}=#{value}"
      end
    end

    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    config.autoload_paths << Rails.root.join("app/components")

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks collavre/version.rb])

    config.app_version = Collavre::VERSION

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    config.hosts << "72237274b26d.ngrok.app"
  end
end
