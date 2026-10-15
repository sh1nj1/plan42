module Collavre
  module Creatives
    class PptPreviewsController < Collavre::ApplicationController
      allow_unauthenticated_access
      before_action :resume_session
      before_action :enforce_creatives_login_policy

      def show
        @blob = preview_blob
        return if performed?
        return head :not_found unless @blob
        return head :not_found unless @blob.filename.extension.downcase == "pptx"

        response.headers["Cache-Control"] = "private, no-store"
        @slides = PptPreview.slides(@blob)
        render layout: "collavre/slide"
      rescue PptRenderer::InvalidArchive, Zip::Error, Nokogiri::XML::SyntaxError
        render plain: t("collavre.ppt_viewer.invalid"), status: :unprocessable_entity
      end

      private

      def preview_blob
        return creative_blob if params[:creative_id]

        blob = ActiveStorage::Blob.find_signed(params[:id])
        return unless blob
        return blob if upload_preview_allowed?(blob)

        origins = Creative.joins(:files_attachments).where(origin_id: nil,
          active_storage_attachments: { blob_id: blob.id })
        blob if origins.any? { |creative| creative.has_permission?(Current.user, :read) }
      end

      def upload_preview_allowed?(blob)
        !blob.attachments.exists? && BlobAccess.new(blob, user: Current.user).readable?
      end

      def creative_blob
        creative = Creative.find(params[:creative_id]).effective_origin
        unless creative.has_permission?(Current.user, :read)
          head :forbidden
          return
        end

        creative.files.find(params[:id]).blob
      end

      def enforce_creatives_login_policy
        require_authentication if SystemSetting.creatives_login_required?
      end
    end
  end
end
