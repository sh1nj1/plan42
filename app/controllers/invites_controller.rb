class InvitesController < ApplicationController
  allow_unauthenticated_access
  before_action :set_invitation

  def show
    @invitation.update(clicked_at: Time.current) unless @invitation.clicked_at
    @user = User.new(email: @invitation.email)
    render "users/new"
  end

  private

  def set_invitation
    @invitation = Invitation.find_by_token_for(:invite, params[:token])
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to new_user_path, alert: t("invites.invalid")
  end
end
