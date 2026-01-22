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
  end
end
