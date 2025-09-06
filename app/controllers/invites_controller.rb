class InvitesController < ApplicationController
  allow_unauthenticated_access only: :show
  before_action :set_invitation, only: :show

  def create
    creative = Creative.find(params[:creative_id])
    permission = params[:permission] || :read
    invitation = Invitation.create!(inviter: Current.user,
                                    creative: creative,
                                    permission: permission)
    render json: { url: invite_url(token: invitation.generate_token_for(:invite)) }
  end

  def show
    @invitation.update(clicked_at: Time.current) unless @invitation.clicked_at
  end

  private

  def set_invitation
    @invitation = Invitation.find_by_token_for(:invite, params[:token])
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to new_user_path, alert: t("invites.invalid")
  end
end
