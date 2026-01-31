module CollavreNotion
  class Engine < ::Rails::Engine
    isolate_namespace CollavreNotion

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

    initializer "collavre_notion.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreNotion::Engine => "/notion", as: :notion_engine
        match "/auth/notion/callback", to: "collavre_notion/notion_auth#callback", via: [ :get, :post ]
      end
    end

    initializer "collavre_notion.assets" do |app|
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    initializer "collavre_notion.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    initializer "collavre_notion.register_integration", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::IntegrationRegistry)
          Collavre::IntegrationRegistry.register(:notion, {
            label: I18n.t("collavre_notion.integration.label", default: "Notion"),
            icon: "notion",
            description: I18n.t("collavre_notion.integration.description", default: "Export creative trees to Notion pages"),
            routes: CollavreNotion::Engine.routes.url_helpers,
            creative_menu_partial: "collavre_notion/integrations/modal"
          })
        end
      end
    end

    initializer "collavre_notion.user_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        user_class = Collavre.user_class rescue nil
        next unless user_class

        unless user_class.reflect_on_association(:notion_account)
          user_class.has_one :notion_account,
                              class_name: "CollavreNotion::NotionAccount",
                              dependent: :destroy
          Rails.logger.info("[CollavreNotion] Added notion_account association to #{user_class.name}")
        end
      end
    end

    initializer "collavre_notion.creative_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        creative_class = Collavre::Creative rescue nil
        next unless creative_class

        unless creative_class.reflect_on_association(:notion_page_links)
          creative_class.has_many :notion_page_links,
                                  class_name: "CollavreNotion::NotionPageLink",
                                  dependent: :destroy
          Rails.logger.info("[CollavreNotion] Added notion_page_links association to #{creative_class.name}")
        end

        unless creative_class.reflect_on_association(:notion_block_links)
          creative_class.has_many :notion_block_links,
                                  class_name: "CollavreNotion::NotionBlockLink",
                                  dependent: :destroy
          Rails.logger.info("[CollavreNotion] Added notion_block_links association to #{creative_class.name}")
        end
      end
    end
  end
end
