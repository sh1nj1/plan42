module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie

      if Current.session&.user.nil?
        Current.session.destroy if Current.session&.persisted?
        Current.session = nil
      end

      # Check session timeout
      if Current.session&.expired?
        Current.session.destroy
        Current.session = nil
        cookies.delete(:session_id)
        return nil
      end

      # Update last activity timestamp
      Current.session&.touch_activity!

      cookies.delete(:session_id) if cookies.signed[:session_id] && Current.session.nil?

      Current.session
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      if request.get? && !request.path.start_with?("/inbox") && request.format.html?
        session[:return_to_after_authenticating] = request.url
      end
      # Use collavre engine routes for session
      redirect_to collavre.new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || Rails.application.routes.url_helpers.root_path
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end

    def handle_invitation_for(user)
      Invitation.transaction do
        invitation = Invitation.find_by_token_for(:invite, params[:invite_token])
        if invitation
          invitation.update(accepted_at: Time.current, email: user.email)
          CreativeShare.create!(
            creative: invitation.creative,
            user: user,
            permission: invitation.permission,
            shared_by: invitation.inviter
          )
          invitation.creative.create_linked_creative_for_user(user)
        end
      end
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      # ignore invalid invitation token
    end
end
