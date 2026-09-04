module Collavre
  module Creatives
    # Bearer-only multipart upload endpoint for agents/CLI. Creates an
    # ActiveStorage blob from the uploaded bytes, embeds the matching node into
    # the Creative's description, and lets after_save reconcile attach it to
    # creative.files. No server-local paths, no session/CSRF.
    class AttachmentsController < Collavre::ApplicationController
      include Collavre::PublicAssetsHelper

      allow_unauthenticated_access
      skip_forgery_protection
      before_action :authenticate_bearer!

      def create
        creative = Collavre::Creative.find_by(id: params[:creative_id])
        return render(json: { error: "Creative not found" }, status: :not_found) unless creative

        unless creative.has_permission?(Current.user, :write)
          return render(json: { error: "No write permission" }, status: :forbidden)
        end

        unless creative.attachments_embeddable?
          return render(json: { error: "Cannot attach files to GitHub-synced content" }, status: :unprocessable_entity)
        end

        file = params[:file]
        return render(json: { error: "No file provided" }, status: :unprocessable_entity) unless file.respond_to?(:read)

        result = Collavre::Creatives::AiWritePolicy.capture(
          creatives: [ creative, creative.effective_origin ], anchor: creative, external_request: true
        ) { attach_file(creative, file) }
        render json: result
      end

      private

      def attach_file(creative, file)
        io = file.to_io
        content_type = resolved_content_type(file, io)
        io.rewind
        blob = ActiveStorage::Blob.create_and_upload!(
          io: io,
          filename: file.original_filename,
          content_type: content_type
        )

        creative.embed_attachment_blob!(blob)

        {
          success: true,
          signed_id: blob.signed_id,
          filename: blob.filename.to_s,
          content_type: blob.content_type,
          byte_size: blob.byte_size,
          url: public_asset_url(blob)
        }
      end

      # The bundled `collavre` CLI sends application/octet-stream for every part,
      # so treat octet-stream (and blank) as "unknown" and sniff via Marcel —
      # otherwise png/mp4 render as generic download links, not inline media.
      def resolved_content_type(file, io)
        declared = file.content_type.presence
        return declared if declared && declared != "application/octet-stream"

        Marcel::MimeType.for(io, name: file.original_filename).presence ||
          "application/octet-stream"
      end

      # Resolve a Doorkeeper bearer token to Current.user. The MCP middleware
      # only does this for /mcp paths, so this endpoint authenticates itself.
      def authenticate_bearer!
        token_string = Doorkeeper::OAuth::Token.from_request(
          request, *Doorkeeper.configuration.access_token_methods
        )
        token = Doorkeeper::AccessToken.by_token(token_string) if token_string.present?
        user = Collavre::User.find_by(id: token.resource_owner_id) if token&.accessible?

        if user
          Current.user = user
        else
          render json: { error: "Unauthorized" }, status: :unauthorized
        end
      end
    end
  end
end
