module CollavreLinear
  class Engine < ::Rails::Engine
    isolate_namespace CollavreLinear

    config.generators do |g|
      g.test_framework :minitest
    end

    def self.javascript_path
      root.join("app/javascript")
    end

    def self.stylesheet_path
      root.join("app/assets/stylesheets")
    end

    config.i18n.load_path += Dir[root.join("config", "locales", "*.yml")]

    initializer "collavre_linear.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreLinear::Engine => "/linear", as: :linear_engine
      end
    end

    initializer "collavre_linear.assets" do |app|
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    initializer "collavre_linear.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    initializer "collavre_linear.register_integration", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::IntegrationRegistry)
          Collavre::IntegrationRegistry.register(:linear, {
            label: I18n.t("collavre_linear.integration.label", default: "Linear"),
            icon: "linear",
            description: I18n.t("collavre_linear.integration.description", default: "Two-way sync of projects, issues and comments"),
            routes: CollavreLinear::Engine.routes.url_helpers,
            creative_menu_partial: "collavre_linear/integrations/modal"
          })
        end
      end
    end

    initializer "collavre_linear.user_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        user_class = Collavre.user_class rescue nil
        next unless user_class

        unless user_class.reflect_on_association(:linear_account)
          user_class.has_one :linear_account,
                             class_name: "CollavreLinear::Account",
                             foreign_key: :user_id,
                             dependent: :destroy
        end
      end
    end

    initializer "collavre_linear.creative_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        creative_class = Collavre::Creative rescue nil
        next unless creative_class

        unless creative_class.reflect_on_association(:linear_project_links)
          creative_class.has_many :linear_project_links,
                                  class_name: "CollavreLinear::ProjectLink",
                                  foreign_key: :creative_id,
                                  dependent: :destroy
        end

        unless creative_class.reflect_on_association(:linear_issue_links)
          creative_class.has_many :linear_issue_links,
                                  class_name: "CollavreLinear::IssueLink",
                                  foreign_key: :creative_id,
                                  dependent: :destroy
        end

        if creative_class.respond_to?(:register_reserved_metadata_key)
          creative_class.register_reserved_metadata_key("linear")
        end
      end
    end
  end
end
