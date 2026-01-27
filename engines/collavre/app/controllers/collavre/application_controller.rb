module Collavre
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    private

    # Helper to get the engine's routes
    def collavre_engine
      Collavre::Engine.routes.url_helpers
    end

    # Note: main_app is provided automatically by Rails engines with proper
    # request-aware URL generation (handles script_name, subpath mounting, etc.)
  end
end
