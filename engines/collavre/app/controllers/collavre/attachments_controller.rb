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

      attachment_owned_by_current_user?(blob) ||
        editable_creative_reference?(blob) ||
        orphan_blob?(blob)
    end

    # A blob attached to nothing and referenced by no creative description is a
    # true orphan. The editor direct-uploads an image/video/file, inserts a
    # node, and fires DELETE /attachments/:signed_id when the user removes it;
    # if the node is removed before the blob is ever attached (removed-then-save,
    # so reconcile never sees it in the saved HTML), neither ownership nor a
    # writable-reference can be proven and the DELETE would 403, stranding the
    # blob in storage. Authorizing the purge here is safe: the blob is unused,
    # so removing it cannot break any creative, and any in-use blob still fails
    # this check (an attachment or a referencing description protects it). This
    # mirrors purge_unless_referenced exactly, which then performs the purge.
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
