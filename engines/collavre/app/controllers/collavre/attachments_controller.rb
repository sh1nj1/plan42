module Collavre
  class AttachmentsController < ApplicationController
    # DELETE /attachments/:signed_id
    def destroy
      blob = ActiveStorage::Blob.find_signed(params[:signed_id])

      unless authorized_to_purge?(blob)
        return head :forbidden
      end

      blob.purge
      head :no_content
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue => e
      Rails.logger.error("Failed to delete attachment: #{e.message}")
      head :internal_server_error
    end

    private

    def authorized_to_purge?(blob)
      return false unless Current.user

      attachment_owned_by_current_user?(blob) || editable_creative_reference?(blob)
    end

    def attachment_owned_by_current_user?(blob)
      blob.attachments.any? do |attachment|
        record = attachment.record
        record == Current.user || record.respond_to?(:user_id) && record.user_id == Current.user.id
      end
    end

    def editable_creative_reference?(blob)
      signed_id = blob.signed_id
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%"

      Creative.where("description LIKE ?", pattern).any? do |creative|
        creative.has_permission?(Current.user, :write)
      end
    end
  end
end
