module Collavre
  class InvitesController < ApplicationController
    LINK_PREVIEW_USER_AGENT_PATTERN = /
      bot\b|crawler\b|spider\b|preview\b|scrap(?:e|er)?\b|
      facebookexternalhit|whatsapp|iframely|embedly
    /ix

    allow_unauthenticated_access only: :show
    before_action :set_invitation, only: :show

    def create
      creative = Creative.find(params[:creative_id]).effective_origin
      unless creative.has_permission?(Current.user, :admin)
        return head :forbidden
      end
      permission = params[:permission] || :read
      invitation = Invitation.create!(inviter: Current.user,
                                      creative: creative,
                                      permission: permission,
                                      email: params[:email].presence)
      render json: { url: invite_url(token: invitation.generate_token_for(:invite)) }
    end

    def show
      return if @invitation.clicked_at || link_preview_crawler?

      @invitation.update(clicked_at: Time.current)
    end

    private

    def link_preview_crawler?
      request.user_agent.to_s.match?(LINK_PREVIEW_USER_AGENT_PATTERN)
    end

    def set_invitation
      @invitation = Invitation.find_by_token_for(:invite, params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to main_app.new_user_path, alert: t("collavre.invites.invalid")
    end
  end
end
