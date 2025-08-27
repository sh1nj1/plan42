class GoogleAuthController < ApplicationController
  allow_unauthenticated_access only: :callback

  def callback
    auth = request.env["omniauth.auth"]
    user = User.find_or_initialize_by(email: auth.info.email)
    if user.new_record?
      user.name = auth.info.name.presence || auth.info.email.split("@").first
      random_password = SecureRandom.hex(16)
      user.password = random_password
      user.password_confirmation = random_password
      user.email_verified_at = Time.current
    end

    if auth.info.image.present? && !user.avatar.attached? && user.avatar_url.blank?
      user.avatar_url = auth.info.image
    end

    # for personal google service (like google calendar)
    user.google_uid = auth.uid
    user.google_access_token = auth.credentials.token
    user.google_refresh_token = auth.credentials.refresh_token || user.google_refresh_token
    user.google_token_expires_at = Time.at(auth.credentials.expires_at) if auth.credentials.expires_at

    user.save! if user.new_record? || user.changed?

    # Ensure app calendar exists if the granted scope allows creating an app calendar
    begin
      GoogleCalendarService.new(user: user).ensure_app_calendar!
    rescue => e
      Rails.logger.error("Post-login calendar setup failed: #{e.message}")
    end

    start_new_session_for(user)
    redirect_to after_authentication_url
  end
end
