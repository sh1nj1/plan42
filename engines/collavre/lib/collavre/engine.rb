module Collavre
  class Engine < ::Rails::Engine
    isolate_namespace Collavre

    config.generators do |g|
      g.test_framework :minitest
    end

    initializer "collavre.assets" do |app|
      app.config.assets.precompile += %w[collavre.js collavre.css] if app.config.respond_to?(:assets)
    end

    initializer "collavre.importmap", before: "importmap" do |app|
      if app.config.respond_to?(:importmap)
        app.config.importmap.paths << Engine.root.join("config/importmap.rb")
      end
    end

    # Allow engine controllers to fall back to host app views during migration
    # This enables gradual view migration - views can stay in host app until moved to engine
    initializer "collavre.view_paths" do
      ActiveSupport.on_load(:action_controller) do
        append_view_path Rails.root.join("app/views")
      end
    end

    # Make engine URL helpers available to views via the `collavre` helper method
    # This avoids conflicts with main app routes while still providing access to engine routes
    initializer "collavre.url_helpers" do
      ActiveSupport.on_load(:action_controller_base) do
        helper do
          def collavre
            Collavre::Engine.routes.url_helpers
          end
        end
      end
    end
  end
end
