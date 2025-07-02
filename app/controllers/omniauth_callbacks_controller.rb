class OmniauthCallbacksController < ApplicationController
  allow_unauthenticated_access only: [ :google_oauth2, :failure ]

  def google_oauth2
    auth = request.env["omniauth.auth"]
    user = User.find_or_create_from_google(auth)
    start_new_session_for user
    redirect_to after_authentication_url
  rescue ActiveRecord::RecordInvalid
    redirect_to new_session_path, alert: t("users.sessions.new.try_again_later")
  end

  def failure
    redirect_to new_session_path, alert: t("users.sessions.new.try_again_later")
  end
end
