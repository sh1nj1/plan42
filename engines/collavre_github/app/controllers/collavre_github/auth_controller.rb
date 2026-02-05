module CollavreGithub
  class AuthController < ApplicationController
    allow_unauthenticated_access only: :callback
    before_action -> { enforce_auth_provider!(:github) }, only: :callback

    def callback
      auth = request.env["omniauth.auth"]
      account = CollavreGithub::Account.find_or_initialize_by(github_uid: auth.uid)

      if account.new_record?
        unless Current.user
          redirect_to main_app.new_session_path, alert: I18n.t("collavre_github.auth.login_first")
          return
        end
        account.user_id = Current.user.id
      end

      account.token = auth.credentials.token
      account.login = auth.info.nickname
      account.name = auth.info.name
      account.avatar_url = auth.info.image
      account.save!

      redirect_to main_app.creatives_path, notice: I18n.t("collavre_github.auth.connected")
    end
  end
end
