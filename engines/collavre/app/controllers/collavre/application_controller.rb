module Collavre
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    private

    # Helper to get the engine's routes
    def collavre_engine
      Collavre::Engine.routes.url_helpers
    end

    # Helper to access main app routes from engine views/controllers
    def main_app
      Rails.application.routes.url_helpers
    end
  end
end
