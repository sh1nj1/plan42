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
    # return them to their last readable Creative when the authenticated home
    # page is the Creative index; otherwise honor the configured home page.
    # The middleware preserves "/" as a stable URL for unauthenticated
    # visitors; authenticated users get a real URL change so the address
    # bar reflects state.
    #
    # Loop safety: the env flag is only set when PATH_INFO == "/" hits
    # the middleware. Direct visits to the redirect target never trip it,
    # so comparing request.path to target would be wrong here — when both
    # home_page_path and home_page_path_authenticated resolve to the same
    # path, the middleware has already rewritten request.path to that
    # target while the browser URL is still "/", and we must still
    # redirect so the address bar reflects state.
    def redirect_authenticated_root_to_home
      return unless request.get? || request.head?
      return unless request.env["collavre.root_request"]
      return unless authenticated?

      target = last_visited_creative_path || SystemSetting.home_page_path_authenticated
      return if target.blank?
      return if target == "/"

      redirect_to target
    end

    def last_visited_creative_path
      home_path = SystemSetting.home_page_path_authenticated.chomp("/")
      return unless home_path == "/creatives" || home_path == "/creatives.html"

      creative = Current.user.last_visited_creative
      return unless creative&.has_permission?(Current.user, :read)

      collavre_engine.creatives_path(id: creative.id, script_name: request.script_name)
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
