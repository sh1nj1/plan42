module CollavreGithub
  class Engine < ::Rails::Engine
    isolate_namespace CollavreGithub

    config.generators do |g|
      g.test_framework :minitest
    end

    def self.javascript_path
      root.join("app/javascript")
    end

    config.i18n.load_path += Dir[root.join("config", "locales", "*.yml")]

    initializer "collavre_github.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreGithub::Engine => "/github", as: :github_engine
        match "/auth/github/callback", to: "collavre_github/auth#callback", via: [:get, :post]
      end
    end

    initializer "collavre_github.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    initializer "collavre_github.register_integration", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::IntegrationRegistry)
          Collavre::IntegrationRegistry.register(:github, {
            label: I18n.t("collavre_github.integration.label", default: "GitHub"),
            icon: "github",
            description: I18n.t("collavre_github.integration.description", default: "Connect repositories and receive webhook events"),
            routes: CollavreGithub::Engine.routes.url_helpers,
            creative_menu_partial: "collavre_github/integrations/modal"
          })
        end
      end
    end

    initializer "collavre_github.user_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        user_class = Collavre.user_class rescue nil
        next unless user_class

        unless user_class.reflect_on_association(:github_account)
          user_class.has_one :github_account,
                             class_name: "CollavreGithub::Account",
                             foreign_key: :user_id,
                             dependent: :destroy
          Rails.logger.info("[CollavreGithub] Added github_account association to #{user_class.name}")
        end
      end
    end

    initializer "collavre_github.creative_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        creative_class = Collavre::Creative rescue nil
        next unless creative_class

        unless creative_class.reflect_on_association(:github_repository_links)
          creative_class.has_many :github_repository_links,
                                  class_name: "CollavreGithub::RepositoryLink",
                                  foreign_key: :creative_id,
                                  dependent: :destroy
          Rails.logger.info("[CollavreGithub] Added github_repository_links association to #{creative_class.name}")
        end
      end
    end
  end
end
