module CollavreSlack
  class Engine < ::Rails::Engine
    isolate_namespace CollavreSlack

    config.generators do |g|
      g.test_framework :minitest
    end

    # Load locale files
    config.i18n.load_path += Dir[root.join("config", "locales", "*.yml")]

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
  end
end
