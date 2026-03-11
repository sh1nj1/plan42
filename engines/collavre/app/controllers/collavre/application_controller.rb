module Collavre
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    # Include a fresh CSRF token in every response header so that
    # JavaScript callers can update the stale <meta> tag after the
    # browser has been in the background (OS window switch, tab
    # freeze, etc.).  Without this, the meta-tag token drifts out
    # of sync with the session cookie and POSTs fail with 422.
    after_action :set_csrf_token_header

    private

    def set_csrf_token_header
      return unless protect_against_forgery?

      response.headers["X-CSRF-Token"] = form_authenticity_token
    end

    # Helper to get the engine's routes
    def collavre_engine
      Collavre::Engine.routes.url_helpers
    end

    # Note: main_app is provided automatically by Rails engines with proper
    # request-aware URL generation (handles script_name, subpath mounting, etc.)
  end
end
