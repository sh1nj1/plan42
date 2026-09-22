module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeAttachFilesService
    extend T::Sig
    extend ToolMeta
    include Collavre::PublicAssetsHelper

    tool_name "creative_attach_files_service"
    tool_description "Attach inline, agent-generated TEXT content (markdown, html, svg, plain text) to a Creative. The content is stored as an ActiveStorage blob, embedded into the Creative's description, and served via CloudFront-cached /public-assets URLs.\n\nUse this for content the agent produced as text (notes, generated markdown/html/svg).\n\nFor BINARY files already on disk (png, mp4, pdf), use the CLI `collavre attach --creative <id> --file <path>` instead — it uploads the raw bytes over a bearer multipart HTTP endpoint without base64 bloat.\n\nRequires :write permission on the target Creative. A Creative with inherited ai_write_policy=review stores a draft in History for approval."

    tool_param :creative_id, description: "ID of the Creative to attach content to.", required: true
    tool_param :files, description: "Array of objects: { filename, content, content_type? }. `content` is the literal UTF-8 text to store (e.g. markdown/html/svg source). `content_type` is inferred from the filename when omitted.", required: true

    sig { params(creative_id: Integer, files: T::Array[T::Hash[String, T.untyped]]).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:, files:)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative
      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on Creative", id: creative_id }
      end
      unless creative.attachments_embeddable?
        return { error: "Cannot attach files to GitHub-synced content", id: creative_id }
      end
      return { error: "No files provided" } if files.blank?
      # Validate the entire payload before creating any blob, so a bad entry
      # later in the array never leaves an orphaned blob from an earlier one.
      return { error: "Each file requires a filename" } if files.any? { |f| f["filename"].to_s.blank? }

      Creatives::AiWritePolicy.capture(
        creatives: [ creative, creative.effective_origin ], anchor: Creatives::AiWritePolicy.agent_anchor || creative
      ) { attach_files(creative, files) }
    end

    private

    def attach_files(creative, files)
      blobs = files.map do |f|
        name = f["filename"].to_s
        content = f["content"].to_s

        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(content),
          filename: name,
          content_type: f["content_type"].presence || Marcel::MimeType.for(name: name) || "text/plain"
        )
      end

      blobs.each { |blob| creative.embed_attachment_blob!(blob) }

      {
        success: true,
        creative_id: creative.id,
        attachments: blobs.map { |b|
          {
            signed_id: b.signed_id,
            filename: b.filename.to_s,
            content_type: b.content_type,
            byte_size: b.byte_size,
            url: public_asset_url(b)
          }
        }
      }
    end
  end
end
end
