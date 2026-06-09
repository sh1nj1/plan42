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

    # A blob can be shared across creatives (description HTML copied between
    # them). The editor fires this DELETE for removed nodes after its PATCH, so
    # purging unconditionally could delete a blob another creative still
    # references, 404-ing its description. Only purge a true orphan.
    def purge_unless_referenced(blob)
      signed_id = blob.signed_id
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(signed_id)}%"

      return if Creative.where("description LIKE ?", pattern).exists?
      return if ActiveStorage::Attachment.where(blob_id: blob.id).exists?

      blob.purge
    end

    def authorized_to_purge?(blob)
      return false unless Current.user

      attachment_owned_by_current_user?(blob) ||
        editable_creative_reference?(blob) ||
        orphan_blob?(blob)
    end

    # Authorize purging a true orphan (attached to nothing, in no description).
    # Covers a node removed before its blob was ever attached (removed-then-save,
    # so reconcile never sees it), which can prove neither ownership nor a
    # writable reference and would otherwise 403, stranding the blob. Safe: any
    # in-use blob still fails this check. Mirrors purge_unless_referenced.
    def orphan_blob?(blob)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(blob.signed_id)}%"

      !ActiveStorage::Attachment.where(blob_id: blob.id).exists? &&
        !Creative.where("description LIKE ?", pattern).exists?
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
