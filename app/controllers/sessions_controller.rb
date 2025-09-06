class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_url, alert: I18n.t("users.sessions.new.try_again_later") }

  def new
  end

  def create
    credentials = params.permit(:email, :password)
    if (user = User.authenticate_by(credentials))
      if user.email_verified?
        handle_invitation_for(user) if params[:invite_token].present?
        start_new_session_for user
        tz = params[:timezone]
        user.update(timezone: tz) if tz.present? && user.timezone != tz
        redirect_to after_authentication_url
      else
        redirect_to new_session_path, alert: I18n.t("users.sessions.new.email_not_verified")
      end
    else
      redirect_to new_session_path, alert: I18n.t("users.sessions.new.try_another_email_or_password")
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path
  end

  private

  def handle_invitation_for(user)
    Invitation.transaction do
      invitation = Invitation.find_by_token_for(:invite, params[:invite_token])
      invitation.update(accepted_at: Time.current, email: user.email)
      CreativeShare.create!(creative: invitation.creative, user: user, permission: invitation.permission)
      invitation.creative.create_linked_creative_for_user(user)
    end
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    # ignore invalid invitation token
  end
end
