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
  end
end
