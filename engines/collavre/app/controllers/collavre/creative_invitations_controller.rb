# frozen_string_literal: true

module Collavre
  class CreativeInvitationsController < ApplicationController
    before_action :set_invitation
    before_action :authorize_admin!

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

    def set_invitation
      @invitation = Invitation.find(params[:id])
      @creative = @invitation.creative
    end

    def authorize_admin!
      return if @creative.has_permission?(Current.user, :admin)

      respond_to do |format|
        format.html { redirect_back fallback_location: main_app.root_path, alert: t("collavre.creatives.errors.no_permission") }
        format.json { render json: { error: t("collavre.creatives.errors.no_permission") }, status: :forbidden }
      end
    end
  end
end
