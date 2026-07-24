module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeRemoveAttachmentService
    extend T::Sig
    extend ToolMeta

    tool_name "creative_remove_attachment_service"
    tool_description "Remove a single attachment from a Creative by its signed_id. Requires :write permission. Strips the attachment's node from the description and purges the underlying blob asynchronously when nothing else references it."

    tool_param :creative_id, description: "ID of the Creative.", required: true
    tool_param :signed_id, description: "signed_id of the blob (from creative_list_attachments_service or creative_attach_files_service response).", required: true

    sig { params(creative_id: Integer, signed_id: String).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:, signed_id:)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative

      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on Creative", id: creative_id }
      end

      # HTML is the source of truth: strip the node from the description and let
      # after_save reconcile detach + safe-purge the blob. Removing only the
      # ActiveStorage attachment would leave a dangling node in the description
      # (broken asset, or reconciled back into creative.files on the next save).
      removed = creative.remove_attachment!(signed_id)
      return { error: "Attachment not found on this Creative" } unless removed

      { success: true, creative_id: creative.id, removed_signed_id: signed_id }
    end
  end
end
end
