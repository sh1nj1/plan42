module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CreativeAttachFilesService
    extend T::Sig
    extend ToolMeta
    include Collavre::PublicAssetsHelper

    tool_name "creative_attach_files_service"
    tool_description "Attach one or more local files (images, video, documents) to a Creative. Files are uploaded to ActiveStorage (S3) and served publicly via CloudFront-cached /public-assets URLs.\n\nUse this to:\n- Upload landing page assets (hero images, demo videos)\n- Attach reference documents to a task\n\nRequires :write permission on the target Creative."

    tool_param :creative_id, description: "ID of the Creative to attach files to.", required: true
    tool_param :file_paths, description: "Absolute local file paths to upload. All paths must exist; if any is missing the entire call fails atomically.", required: true

    sig { params(creative_id: Integer, file_paths: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id:, file_paths:)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative

      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on Creative", id: creative_id }
      end

      missing = file_paths.reject { |p| File.file?(p) }
      if missing.any?
        return { error: "Missing files", missing: missing }
      end

      attached = []
      ActiveRecord::Base.transaction do
        file_paths.each do |path|
          File.open(path, "rb") do |io|
            creative.files.attach(
              io: io,
              filename: File.basename(path),
              content_type: Marcel::MimeType.for(Pathname.new(path)) || "application/octet-stream"
            )
          end
        end
        creative.save!
        attached = creative.files.last(file_paths.length)
      end

      {
        success: true,
        creative_id: creative.id,
        attachments: attached.map { |a|
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
