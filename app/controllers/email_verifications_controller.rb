class EmailVerificationsController < ApplicationController
  allow_unauthenticated_access

  def show
    user = User.find_by_token_for(:email_verification, params[:token])
    user.update!(email_verified_at: Time.current) unless user.email_verified_at?
    redirect_to new_session_path, notice: t("users.email_verified")
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to new_user_path, alert: t("users.verification_invalid")
  end
end
