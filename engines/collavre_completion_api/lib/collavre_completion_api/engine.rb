# frozen_string_literal: true

module CollavreCompletionApi
  class Engine < ::Rails::Engine
    isolate_namespace CollavreCompletionApi

    config.generators do |g|
      g.test_framework :minitest
    end

    # Auto-mount engine routes under the Collavre engine
    initializer "collavre_completion_api.routes", before: :add_routing_paths do |app|
      app.routes.append do
        mount CollavreCompletionApi::Engine => "/", as: :collavre_completion_api_engine
      end
    end
  end
end
