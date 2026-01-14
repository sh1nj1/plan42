require_relative "../../lib/local_engine_setup"

# Automatically configure all engines in the 'engines/' directory
# We run this on boot (for initial config) and on reload (to pick up view path changes)

# 1. Run immediately for config-level things (Migrations, I18n load path, Middleware)
LocalEngineSetup.run(Rails.application)

# 2. Run on to_prepare for reloaded things (View Paths)
Rails.application.config.to_prepare do
  LocalEngineSetup.run(Rails.application, view_paths_only: true)
end
