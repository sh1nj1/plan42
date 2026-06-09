module Collavre
  class AttachmentsController < ApplicationController
    # DELETE /attachments/:signed_id
    def destroy
      blob = ActiveStorage::Blob.find_signed(params[:signed_id])

      unless authorized_to_purge?(blob)
        return head :forbidden
      end

      purge_unless_referenced(blob)
      head :no_content
    rescue ActiveRecord::RecordNotFound
      head :not_found
    rescue StandardError => e
      Rails.logger.error("Failed to delete attachment: #{e.message}")
      head :internal_server_error
    end

    private

    # Description HTML is the source of truth for creative.files; a blob can be
    # shared across creatives (HTML copied between them, after which each save's
    # reconcile attaches the same blob). The editor still fires this DELETE for
    # removed nodes after its PATCH lands, so purging unconditionally here would
    # delete a blob still referenced by another creative, leaving its description
    # pointing at a 404. Mirror the model's detach_and_maybe_purge guard: only
    # purge a true orphan; otherwise leave reconcile to own the blob lifecycle.
    def purge_unless_referenced(blob)
      signed_id = blob.signed_id
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%"

      return if Creative.where("description LIKE ?", pattern).exists?
      return if ActiveStorage::Attachment.where(blob_id: blob.id).exists?

      blob.purge
    end

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
