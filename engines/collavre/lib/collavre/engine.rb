module Collavre
  class Engine < ::Rails::Engine
    isolate_namespace Collavre

    config.generators do |g|
      g.test_framework :minitest
    end

    # Add engine migrations to main app's migration path
    # This allows migrations to live in the engine but be run from the host app
    initializer "collavre.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    initializer "collavre.assets" do |app|
      app.config.assets.precompile += %w[collavre.js] if app.config.respond_to?(:assets)

      # Add engine stylesheets to asset paths for Propshaft
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    initializer "collavre.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << Engine.root.join("config/importmap.rb")
      end
    end

    # Add engine locales to I18n load path
    # Host app can override these translations by defining the same keys
    initializer "collavre.i18n" do |app|
      config.i18n.load_path += Dir[root.join("config/locales/**/*.yml")]
    end

    # Allow engine controllers to fall back to host app views during migration
    # This enables gradual view migration - views can stay in host app until moved to engine
    initializer "collavre.view_paths" do
      ActiveSupport.on_load(:action_controller) do
        append_view_path Rails.root.join("app/views")
      end
    end

    # Make engine URL helpers available to controllers and views via the `collavre` method
    # This avoids conflicts with main app routes while still providing access to engine routes
    initializer "collavre.url_helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        # Add to controllers
        define_method :collavre do
          Collavre::Engine.routes.url_helpers
        end
        private :collavre

        # Add to views via helper
        helper do
          def collavre
            Collavre::Engine.routes.url_helpers
          end
        end
      end
    end
  end
end
