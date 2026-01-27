module Collavre
  class EmailVerificationsController < ApplicationController
    allow_unauthenticated_access

    def show
      user = Collavre::User.find_by_token_for(:email_verification, params[:token])

      if user
        user.update!(email_verified_at: Time.current)
        redirect_to new_session_path, notice: I18n.t("collavre.users.email_verified")
      else
        redirect_to new_session_path, alert: I18n.t("collavre.users.email_verification.invalid_token")
      end
    end
  end
end
