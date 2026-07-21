# frozen_string_literal: true

module CollavreLinear
  class AuthController < ApplicationController
    # callback is reached after the user authorizes on Linear's site; no
    # session exists yet at that point so we allow unauthenticated access.
    # We then require a logged-in user to associate the account.
    before_action :require_authenticated_user!, only: %i[callback store_creative setup]

    # GET /linear/auth/callback?code=...&state=...
    # Exchange the authorization code, create/update the Account, capture
    # the OAuth app actor id via the GraphQL viewer query.
    def callback
      expected_state = session.delete(:linear_oauth_state)
      unless params[:state].present? && params[:state] == expected_state
        redirect_to collavre.creatives_path,
                    alert: I18n.t("collavre_linear.auth.invalid_state",
                                  default: "Invalid OAuth state. Please try connecting again.")
        return
      end

      tokens = OAuthTokenService.exchange(params[:code])

      # Build a temporary account so we can call the viewer query
      temp_account = CollavreLinear::Account.new(
        access_token: tokens[:access_token]
      )
      client = CollavreLinear::Client.new(temp_account)
      viewer = client.viewer_and_app_actor

      # Never reassign a Linear identity already owned by another Collavre user
      # (that would steal their account + project links). Bind by the CURRENT
      # user instead (user_id is unique — one Linear account per user), so a
      # reconnect with a different Linear UID updates in place rather than
      # violating the unique index.
      if CollavreLinear::Account.where(linear_uid: viewer[:user_id])
                                .where.not(user_id: Current.user.id).exists?
        redirect_to collavre.creatives_path,
                    alert: I18n.t("collavre_linear.auth.already_linked_other")
        return
      end

      account = CollavreLinear::Account.find_or_initialize_by(
        user_id: Current.user.id
      )

      # A reconnect that lands in a DIFFERENT Linear workspace than the one the
      # existing project links were created under would orphan those links: their
      # team_id / linear_project_id belong to the old workspace, so resync and
      # outbound jobs would run them against the new token and fail or target the
      # wrong Linear context. Refuse when we can prove the workspace changed and
      # links exist; the admin must unlink first. workspace_id is blank on legacy
      # rows, so an unprovable change falls through and never blocks a plain
      # same-workspace token refresh (the reconnect button's actual purpose).
      if account.persisted? &&
         account.workspace_id.present? &&
         account.workspace_id != viewer[:organization_id] &&
         account.project_links.exists?
        redirect_to collavre.creatives_path,
                    alert: I18n.t("collavre_linear.auth.workspace_changed_relink")
        return
      end

      account.linear_uid       = viewer[:user_id]
      account.access_token     = tokens[:access_token]
      account.refresh_token    = tokens[:refresh_token]
      account.token_expires_at = Time.current + tokens[:expires_in].to_i.seconds if tokens[:expires_in]
      account.app_actor_id     = viewer[:app_actor_id]
      account.workspace_id     = viewer[:organization_id]
      account.save!

      creative_id = session.delete(:linear_creative_id)
      if creative_id.present?
        # Redirect to the MOUNTED path (/linear/auth/setup). The engine is
        # detached, so we fold its mount prefix in explicitly via `script_name:`
        # — the bare engine-internal /auth/setup would 404 in the popup.
        redirect_to linear_engine.setup_auth_path(
          creative_id: creative_id,
          script_name: CollavreLinear::Engine::MOUNT_PATH
        )
      else
        redirect_to collavre.creatives_path,
                    notice: I18n.t("collavre_linear.auth.connected", default: "Linear connected.")
      end
    end

    # GET /linear/auth/setup?creative_id=...
    # Setup wizard entry point — mirrors the collavre_github pattern.
    def setup
      @creative_id = params[:creative_id]

      unless @creative_id.present?
        render plain: I18n.t("collavre_linear.integration.missing_creative",
                             default: "creative_id is required"),
               status: :bad_request
        return
      end

      @creative = Collavre::Creative.find_by(id: @creative_id)
      unless @creative
        render plain: I18n.t("collavre_linear.integration.missing_creative",
                             default: "Creative not found"),
               status: :not_found
        return
      end

      unless @creative.has_permission?(Current.user, :admin)
        render plain: I18n.t("collavre_linear.errors.forbidden",
                             default: "Access denied"),
               status: :forbidden
        return
      end

      render layout: false
    end

    # POST /linear/auth/store_creative
    # Persist creative_id and generate a CSRF state token in the session, then
    # redirect the popup window straight to Linear's OAuth screen. The form
    # POSTs into a popup with no JS handler, so returning JSON here would just
    # render raw JSON in the popup and never start OAuth — a 303 redirect makes
    # the popup follow through to Linear.
    def store_creative
      missing = OAuthTokenService.missing_config
      if missing.any?
        render plain: I18n.t("collavre_linear.auth.oauth_config_missing",
                             keys: missing.join(", ")),
               status: :service_unavailable
        return
      end

      session[:linear_creative_id] = params[:creative_id]
      state = SecureRandom.hex(24)
      session[:linear_oauth_state] = state
      authorize_url = OAuthTokenService.authorize_url(state: state, creative_id: params[:creative_id])
      redirect_to authorize_url, allow_other_host: true, status: :see_other
    end

    private

    def require_authenticated_user!
      return if Current.user

      redirect_to collavre.new_session_path,
                  alert: I18n.t("collavre_linear.auth.login_first",
                                default: "Please log in first.")
    end

    def linear_engine
      CollavreLinear::Engine.routes.url_helpers
    end
  end
end
