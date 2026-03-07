module Collavre
  module UsersController::Registration
    extend ActiveSupport::Concern

    included do
      allow_unauthenticated_access only: %i[new create exists]
      before_action -> { enforce_auth_provider!(:email) }, only: [ :new, :create ]
    end

    def new
      @user = Collavre::User.new
      if params[:invite_token].present?
        @invitation = Collavre::Invitation.find_by_token_for(:invite, params[:invite_token])
        @user.email = @invitation&.email
      end
    end

    def create
      @user = Collavre::User.new(user_params)
      Collavre::Invitation.transaction do
        if params[:invite_token].present?
          invitation = Collavre::Invitation.find_by_token_for(:invite, params[:invite_token])
          if invitation
            @invitation = invitation
            @user.email = invitation.email
          end
        end
        if @user.save
          if invitation
            invitation.update(accepted_at: Time.current)
            Collavre::CreativeShare.create!(
              creative: invitation.creative,
              user: @user,
              permission: invitation.permission,
              shared_by: invitation.inviter
            )
            Collavre::Contact.ensure(user: invitation.inviter, contact_user: @user)
            invitation.creative.create_linked_creative_for_user(@user)
          end
          Collavre::EmailVerificationMailer.verify(@user).deliver_later
          session.delete(:return_to_after_authenticating)
          redirect_to new_session_path, notice: I18n.t("collavre.users.new.success_sign_up")
        else
          render :new, status: :unprocessable_entity
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        flash.now[:alert] = I18n.t("collavre.invites.invalid")
        render :new, status: :unprocessable_entity
      end
    end

    def exists
      user = Collavre::User.find_by(email: params[:email])
      render json: { exists: user.present? }
    end

    private

    def user_params
      params.require(:user).permit(:email, :password, :password_confirmation, :name)
    end
  end
end
