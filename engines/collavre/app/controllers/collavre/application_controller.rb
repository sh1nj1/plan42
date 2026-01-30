module Collavre
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    helper_method :slack_engine

    private

    # Helper to get the engine's routes
    def collavre_engine
      Collavre::Engine.routes.url_helpers
    end

    # Helper to get the Slack engine's routes
    def slack_engine
      CollavreSlack::Engine.routes.url_helpers
    end

    # Note: main_app is provided automatically by Rails engines with proper
    # request-aware URL generation (handles script_name, subpath mounting, etc.)
  end
end
