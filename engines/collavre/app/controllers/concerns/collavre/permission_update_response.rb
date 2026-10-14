# frozen_string_literal: true

module Collavre
  module PermissionUpdateResponse
    extend ActiveSupport::Concern

    private

    def update_permission_response(record)
      if record.update(permission: params[:permission])
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, notice: t("collavre.creatives.share.permission_updated") }
          format.json { render json: { permission: record.permission }, status: :ok }
        end
      else
        respond_to do |format|
          format.html { redirect_back fallback_location: main_app.root_path, alert: record.errors.full_messages.to_sentence }
          format.json { render json: { error: record.errors.full_messages.to_sentence }, status: :unprocessable_entity }
        end
      end
    end
  end
end
