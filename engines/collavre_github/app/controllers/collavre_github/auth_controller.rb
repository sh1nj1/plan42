module CollavreGithub
  class AuthController < ApplicationController
    allow_unauthenticated_access only: :callback
    before_action -> { enforce_auth_provider!(:github) }, only: :callback

    def callback
      auth = request.env["omniauth.auth"]
      account = CollavreGithub::Account.find_or_initialize_by(github_uid: auth.uid)

      if account.new_record?
        unless Current.user
          redirect_to collavre.new_session_path, alert: I18n.t("collavre_github.auth.login_first")
          return
        end
        account.user_id = Current.user.id
      end

      account.token = auth.credentials.token
      account.login = auth.info.nickname
      account.name = auth.info.name
      account.avatar_url = auth.info.image
      account.save!

      creative_id = session.delete(:github_creative_id)
      if creative_id.present?
        redirect_to setup_auth_path(creative_id: creative_id)
      else
        redirect_to collavre.creatives_path, notice: I18n.t("collavre_github.auth.connected")
      end
    end

    def setup
      @creative_id = params[:creative_id]
      unless @creative_id.present?
        render plain: I18n.t("collavre_github.integration.missing_creative"), status: :bad_request
        return
      end

      @creative = Collavre::Creative.find_by(id: @creative_id)
      unless @creative
        render plain: I18n.t("collavre_github.integration.missing_creative"), status: :not_found
        return
      end

      unless @creative.has_permission?(Current.user, :admin)
        render plain: I18n.t("collavre_github.errors.forbidden"), status: :forbidden
        return
      end

      render layout: false
    end

    def store_creative
      session[:github_creative_id] = params[:creative_id]
      head :ok
    end
  end
end
