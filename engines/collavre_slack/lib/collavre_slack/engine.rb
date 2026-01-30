module CollavreSlack
  class Engine < ::Rails::Engine
    isolate_namespace CollavreSlack

    config.generators do |g|
      g.test_framework :minitest
    end

    initializer "collavre_slack.migrations" do |app|
      unless app.root.to_s.match?(root.to_s)
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    # Hook into Comment creation to dispatch messages to Slack
    initializer "collavre_slack.comment_hooks" do
      ActiveSupport.on_load(:active_record) do
        Rails.application.config.after_initialize do
          if defined?(Collavre::Comment)
            Collavre::Comment.include(CollavreSlack::SlackDispatchable)
            Rails.logger.info("[CollavreSlack] SlackDispatchable included in Collavre::Comment")
          end

          if defined?(Collavre::CommentReaction)
            Collavre::CommentReaction.include(CollavreSlack::SlackReactionDispatchable)
            Rails.logger.info("[CollavreSlack] SlackReactionDispatchable included in Collavre::CommentReaction")
          end
        end
      end
    end
  end
end
