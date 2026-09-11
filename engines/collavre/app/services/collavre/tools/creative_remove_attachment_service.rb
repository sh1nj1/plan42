module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeRemoveAttachmentService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_remove_attachment_service"
    tool_description "Remove a single attachment from a Creative by its signed_id. Requires :write permission. Strips the attachment's node from the description and purges the underlying blob asynchronously when nothing else references it. A Creative with inherited ai_write_policy=review stores a draft in History for approval."

    tool_param :creative_id, description: "ID of the Creative.", required: true
    tool_param :signed_id, description: "signed_id of the blob (from creative_list_attachments_service or creative_attach_files_service response).", required: true

    sig { params(creative_id: Integer, signed_id: String).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:, signed_id:)
      raise I18n.t("collavre.tools.creative_remove_attachment.errors.current_user_required") unless Current.user

      creative = Creative.find_by(id: creative_id)
      return error(:creative_not_found, id: creative_id) unless creative

      unless creative.has_permission?(Current.user, :write)
        return error(:write_permission, id: creative_id)
      end

      targets = [ creative, creative.effective_origin ]
      if Creatives::AiWritePolicy.review_required?(targets) && unembedded_attachment?(creative, signed_id)
        return error(:unembedded_review)
      end

      Creatives::AiWritePolicy.capture(
        creatives: targets, anchor: Creatives::AiWritePolicy.agent_anchor || creative
      ) { remove_attachment(creative, signed_id) }
    end

    private

    def unembedded_attachment?(creative, signed_id)
      target = creative.effective_origin
      blob = ActiveStorage::Blob.find_signed(signed_id)
      return false unless blob && target.files.attachments.exists?(blob_id: blob.id)

      !Creatives::History.extract_signed_ids(target.description).include?(signed_id)
    end

    def remove_attachment(creative, signed_id)
      # HTML is the source of truth: strip the node from the description and let
      # after_save reconcile detach + safe-purge the blob. Removing only the
      # ActiveStorage attachment would leave a dangling node in the description
      # (broken asset, or reconciled back into creative.files on the next save).
      removed = creative.remove_attachment!(signed_id)
      return error(:attachment_not_found) unless removed

      { success: true, creative_id: creative.id, removed_signed_id: signed_id }
    end

    def error(key, **attributes)
      { error: I18n.t("collavre.tools.creative_remove_attachment.errors.#{key}"), **attributes }
    end
  end
end
end
