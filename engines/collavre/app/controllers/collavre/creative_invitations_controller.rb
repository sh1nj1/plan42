# frozen_string_literal: true

module Collavre
  class CreativeInvitationsController < ApplicationController
    before_action :set_invitation

    def update
      if @invitation.update(permission: params[:permission])
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, notice: t("collavre.creatives.share.permission_updated") }
          format.json { render json: { permission: @invitation.permission }, status: :ok }
        end
      else
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: @invitation.errors.full_messages.to_sentence }
          format.json { render json: { error: @invitation.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end

    def destroy
      @invitation.destroy
      respond_to do |format|
        format.html { redirect_back fallback_location: main_app.root_path, notice: t("collavre.contacts.org_chart.invite_cancelled") }
        format.json { head :no_content }
      end
    end

    private

    # Scoped lookup: only returns the invitation if Current.user has admin
    # permission on its creative. Raises ActiveRecord::RecordNotFound otherwise
    # so that record existence is not leaked to unauthorized users.
    def set_invitation
      invitation = Invitation.find_by(id: params[:id])
      creative = invitation&.creative
      raise ActiveRecord::RecordNotFound unless creative&.has_permission?(Current.user, :admin)

      @invitation = invitation
      @creative = creative
    end
  end
end
