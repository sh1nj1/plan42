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
      tokens = OAuthTokenService.exchange(params[:code])

      # Build a temporary account so we can call the viewer query
      temp_account = CollavreLinear::Account.new(
        access_token: tokens[:access_token]
      )
      client = CollavreLinear::Client.new(temp_account)
      viewer = client.viewer_and_app_actor

      account = CollavreLinear::Account.find_or_initialize_by(
        linear_uid: viewer[:user_id]
      )
      account.user_id          = Current.user.id
      account.access_token     = tokens[:access_token]
      account.refresh_token    = tokens[:refresh_token]
      account.token_expires_at = Time.current + tokens[:expires_in].to_i.seconds if tokens[:expires_in]
      account.app_actor_id     = viewer[:app_actor_id]
      account.workspace_id     = viewer[:organization_id]
      account.save!

      creative_id = session.delete(:linear_creative_id)
      if creative_id.present?
        redirect_to linear_engine.setup_auth_path(creative_id: creative_id)
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
    # Persist creative_id in the session before redirecting to Linear OAuth.
    def store_creative
      session[:linear_creative_id] = params[:creative_id]
      head :ok
    end

    private

    def require_authenticated_user!
      unless Current.user
        redirect_to collavre.new_session_path,
                    alert: I18n.t("collavre_linear.auth.login_first",
                                  default: "Please log in first.")
      end
    end

    def linear_engine
      CollavreLinear::Engine.routes.url_helpers
    end
  end
end
