module CollavreSlack
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    private

    def slack_engine
      CollavreSlack::Engine.routes.url_helpers
    end
    helper_method :slack_engine
  end
end
