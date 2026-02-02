module CollavreOpenclaw
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    private

    # Helper to access this engine's routes
    def collavre_openclaw
      CollavreOpenclaw::Engine.routes.url_helpers
    end

    # Helper to access Collavre engine routes
    def collavre
      Collavre::Engine.routes.url_helpers
    end

    # Helper to access main app routes
    def main_app
      Rails.application.routes.url_helpers
    end
  end
end
