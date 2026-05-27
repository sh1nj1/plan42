module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeListAttachmentsService
    extend T::Sig
    extend ToolMeta
    include Collavre::PublicAssetsHelper

    tool_name "creative_list_attachments_service"
    tool_description "List all attachments on a Creative with public URLs, filenames, content types, and sizes. Requires :read permission."

    tool_param :creative_id, description: "ID of the Creative.", required: true

    sig { params(creative_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative

      unless creative.has_permission?(Current.user, :read)
        return { error: "No read permission on Creative", id: creative_id }
      end

      {
        success: true,
        creative_id: creative.id,
        attachments: creative.files.with_all_variant_records.map { |a|
          {
            signed_id: a.blob.signed_id,
            filename: a.filename.to_s,
            content_type: a.content_type,
            byte_size: a.byte_size,
            url: public_asset_url(a.blob)
          }
        }
      }
    end
  end
end
end
