module Collavre
  class ApplicationController < ::ApplicationController
    protect_from_forgery with: :exception

    # Include a fresh CSRF token in every response header so that
    # JavaScript callers can update the stale <meta> tag after the
    # browser has been in the background (OS window switch, tab
    # freeze, etc.).  Without this, the meta-tag token drifts out
    # of sync with the session cookie and POSTs fail with 422.
    after_action :set_csrf_token_header

    before_action :redirect_authenticated_root_to_home

    private

    # If the original request was for "/" and the user is signed in,
    # honor SystemSetting.home_page_path_authenticated by redirecting.
    # The middleware preserves "/" as a stable URL for unauthenticated
    # visitors; authenticated users get a real URL change so the address
    # bar reflects state.
    def redirect_authenticated_root_to_home
      return unless request.get?
      return unless request.env["collavre.root_request"]
      return unless authenticated?

      target = SystemSetting.home_page_path_authenticated
      return if target.blank?
      return if target == "/"
      return if request.path == target

      redirect_to target
    end

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
