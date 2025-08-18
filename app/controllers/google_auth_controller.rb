require "open-uri"

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
      user.save!
    end

    if auth.info.image.present? && !user.avatar.attached?
      begin
        user.avatar.attach(io: URI.open(auth.info.image), filename: "avatar")
      rescue => e
        Rails.logger.error("Failed to fetch Google profile image: #{e.message}")
      end
    end

    start_new_session_for(user)
    redirect_to after_authentication_url
  end
end
