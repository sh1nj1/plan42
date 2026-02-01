module CollavreOpenclaw
  class Engine < ::Rails::Engine
    isolate_namespace CollavreOpenclaw

    config.generators do |g|
      g.test_framework :minitest
    end

    # Path to engine's JavaScript sources for jsbundling-rails integration
    def self.javascript_path
      root.join("app/javascript")
    end

    # Path to engine's stylesheet sources
    def self.stylesheet_path
      root.join("app/assets/stylesheets")
    end

    # Load locale files
    config.i18n.load_path += Dir[root.join("config", "locales", "*.yml")]

    # Auto-mount engine routes
    initializer "collavre_openclaw.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreOpenclaw::Engine => "/openclaw", as: :openclaw_engine
      end
    end

    # Add engine stylesheets to asset paths for Propshaft
    initializer "collavre_openclaw.assets" do |app|
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    initializer "collavre_openclaw.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    # Extend User model with OpenClaw associations
    initializer "collavre_openclaw.user_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        user_class = Collavre.user_class rescue nil
        next unless user_class

        unless user_class.reflect_on_association(:openclaw_account)
          user_class.has_one :openclaw_account,
                             class_name: "CollavreOpenclaw::OpenclawAccount",
                             dependent: :destroy
          Rails.logger.info("[CollavreOpenclaw] Added openclaw_account association to #{user_class.name}")
        end
      end
    end
  end
end
