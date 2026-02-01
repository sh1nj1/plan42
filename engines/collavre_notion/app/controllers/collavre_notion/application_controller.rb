module CollavreNotion
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    private

    def notion_engine
      CollavreNotion::Engine.routes.url_helpers
    end
    helper_method :notion_engine
  end
end
