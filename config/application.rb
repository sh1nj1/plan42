require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Compatibility shim for boot-time `Collavre::IntegrationSettings.fetch` and
# `Collavre::AwsCredentials.{s3,ses_smtp}` callers. Required eagerly so
# `config/storage.yml` (ERB) and `config/environments/*.rb` can use
# `CollavreCompat.call` to drop kwargs an older gem version doesn't accept
# (e.g. `USE_COLLAVRE_GEM=true` pinned to a pre-`boot_safe:` release).
require_relative "../lib/collavre_compat"

# Idempotent fallback encryption key generator (mirrors the
# `config/initializers/active_record_encryption.rb` logic). Required eagerly so
# boot-time DB reads in `config/storage.yml` and `config/environments/*.rb`
# can decrypt admin-saved integration settings BEFORE the initializer runs.
# Without this, deployments relying on the initializer to populate keys hit a
# decryption error and Phase 3 `boot_safe:` rescues fall back to ENV — making
# DB-backed S3 credentials silently downgrade to `:local` storage.
require_relative "../lib/encryption_bootstrap"

# Ensure .env values override existing ENV values when using dotenv's Rails integration
if defined?(Dotenv::Rails)
  Dotenv::Rails.overwrite = true
end

module Collavre
  class Application < Rails::Application
    # closure_tree uses lock file if db is not MySQL or PostgreSQL. set FLOCK_DIR to tmp dir.
    # `||=` so a caller (e.g. the packaged desktop launcher, whose Rails.root is a
    # read-only .app bundle) can point it at a writable path before boot.
    config.before_initialize do
      ENV["FLOCK_DIR"] ||= Rails.root.join("tmp").to_s
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
    # complexity_ratchet.rb and its directory back bin/complexity_check, a
    # CI-only lint tool. They have no business being eager loaded into a booted
    # app, and bin/ runs them outside Rails anyway.
    config.autoload_lib(ignore: %w[assets tasks middleware omniauth complexity_ratchet complexity_ratchet.rb])

    config.app_version = Collavre::VERSION

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
    # config.hosts << "72237274b26d.ngrok.app"

    # Set default URL options for all environments (Mailer, Controller, Background Jobs)
    # Exclude test to avoid OpenRedirectErrors (mismatched host between request: example.com and config: localhost)
    unless Rails.env.test?
      url_options = {
        host: ENV.fetch("DEFAULT_URL_HOST", "localhost"),
        port: ENV.fetch("PORT") { ENV.fetch("DEFAULT_URL_PORT", "3000") },
        protocol: ENV.fetch("DEFAULT_URL_PROTOCOL", "http")
      }

      # Override for production where we typically just use a host without port
      if Rails.env.production?
        url_options = {
          host: ENV.fetch("DEFAULT_URL_HOST", "collavre.com"),
          protocol: "https"
        }
      end

      config.action_mailer.default_url_options = url_options
      config.action_controller.default_url_options = url_options

      # Ensure standard URL helpers (url_for, etc.) also know the host in background jobs/broadcasts
      config.after_initialize do
        Rails.application.routes.default_url_options = url_options
      end
    end
  end
end
