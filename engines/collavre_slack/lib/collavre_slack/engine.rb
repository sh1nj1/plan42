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
  end
end
