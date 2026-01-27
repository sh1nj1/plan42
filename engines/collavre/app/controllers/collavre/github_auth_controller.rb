module Collavre
  class GithubAuthController < ApplicationController
    allow_unauthenticated_access only: :callback
    before_action -> { enforce_auth_provider!(:github) }, only: :callback

    def callback
      auth = request.env["omniauth.auth"]
      gh = Collavre::GithubAccount.find_or_initialize_by(github_uid: auth.uid)

      if gh.new_record?
        unless Current.user
          redirect_to new_session_path, alert: I18n.t("collavre.github_auth.login_first")
          return
        end
        gh.user = Current.user
      end

      gh.token = auth.credentials.token
      gh.login = auth.info.nickname
      gh.save!

      redirect_to creatives_path, notice: I18n.t("collavre.github_auth.connected")
    end
  end
end
