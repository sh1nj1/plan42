module Collavre
  class SessionsController < ApplicationController
    allow_unauthenticated_access only: %i[ new create ]
    before_action -> { enforce_auth_provider!(:email) }, only: :create

    # Read rate limiting from environment-driven configuration
    limit_cfg = Rails.configuration.x.sessions_create_rate_limit || {}
    rate_limit to: (limit_cfg[:to] || 10),
               within: (limit_cfg[:within] || 3.minutes),
               only: :create,
               with: -> { redirect_to new_session_url, alert: I18n.t("collavre.users.sessions.new.try_again_later") }

    def new
    end

    def create
      credentials = params.permit(:email, :password)
      user = Collavre::User.find_by(email: credentials[:email]&.downcase)

      # Check if account is locked
      if user&.locked?
        minutes = (user.remaining_lockout_time / 60.0).ceil
        redirect_to new_session_path, alert: I18n.t("collavre.users.sessions.new.account_locked", minutes: minutes)
        return
      end

      if user && user.authenticate(credentials[:password])
        if user.email_verified?
          user.reset_failed_login_attempts!
          handle_invitation_for(user) if params[:invite_token].present?
          start_new_session_for user
          tz = params[:timezone]
          user.update(timezone: tz) if tz.present? && user.timezone != tz
          redirect_to after_authentication_url
        else
          redirect_to new_session_path, alert: I18n.t("collavre.users.sessions.new.email_not_verified")
        end
      else
        # Record failed login attempt if user exists
        user&.record_failed_login!
        if user&.locked?
          minutes = Collavre::SystemSetting.lockout_duration_minutes
          redirect_to new_session_path, alert: I18n.t("collavre.users.sessions.new.account_locked_now", minutes: minutes)
        else
          redirect_to new_session_path, alert: I18n.t("collavre.users.sessions.new.try_another_email_or_password")
        end
      end
    end

    def destroy
      terminate_session
      redirect_to new_session_path
    end

    private
  end
end
