module CollavreSlack
  class Engine < ::Rails::Engine
    isolate_namespace CollavreSlack

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
    initializer "collavre_slack.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreSlack::Engine => "/slack", as: :slack_engine
      end
    end

    # Add engine stylesheets to asset paths for Propshaft
    initializer "collavre_slack.assets" do |app|
      if app.config.respond_to?(:assets) && app.config.assets.respond_to?(:paths)
        app.config.assets.paths << root.join("app/assets/stylesheets")
      end
    end

    initializer "collavre_slack.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    # Register as Collavre integration
    initializer "collavre_slack.register_integration", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::IntegrationRegistry)
          Collavre::IntegrationRegistry.register(:slack, {
            label: I18n.t("collavre_slack.integration.label", default: "Slack"),
            icon: "slack",
            description: I18n.t("collavre_slack.integration.description", default: "Sync chat messages with Slack channels"),
            routes: CollavreSlack::Engine.routes.url_helpers,
            creative_menu_partial: "collavre_slack/integrations/modal"
          })
        end
      end
    end

    # Hook into Comment and CommentReaction to dispatch to Slack
    initializer "collavre_slack.comment_hooks", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        if defined?(Collavre::Comment) && !Collavre::Comment.included_modules.include?(CollavreSlack::SlackDispatchable)
          Collavre::Comment.include(CollavreSlack::SlackDispatchable)
          Rails.logger.info("[CollavreSlack] SlackDispatchable included in Collavre::Comment")
        end

        if defined?(Collavre::CommentReaction) && !Collavre::CommentReaction.included_modules.include?(CollavreSlack::SlackReactionDispatchable)
          Collavre::CommentReaction.include(CollavreSlack::SlackReactionDispatchable)
          Rails.logger.info("[CollavreSlack] SlackReactionDispatchable included in Collavre::CommentReaction")
        end
      end
    end

    # Extend User model with Slack associations for proper cleanup on user deletion
    initializer "collavre_slack.user_associations", after: :load_config_initializers do
      Rails.application.config.to_prepare do
        user_class = Collavre.user_class rescue nil
        next unless user_class

        unless user_class.reflect_on_association(:slack_accounts)
          user_class.has_many :slack_accounts,
                              class_name: "CollavreSlack::SlackAccount",
                              dependent: :destroy
          Rails.logger.info("[CollavreSlack] Added slack_accounts association to #{user_class.name}")
        end

        unless user_class.reflect_on_association(:slack_user_mappings)
          user_class.has_many :slack_user_mappings,
                              class_name: "CollavreSlack::SlackUserMapping",
                              foreign_key: :collavre_user_id,
                              dependent: :destroy
          Rails.logger.info("[CollavreSlack] Added slack_user_mappings association to #{user_class.name}")
        end
      end
    end
  end
end
