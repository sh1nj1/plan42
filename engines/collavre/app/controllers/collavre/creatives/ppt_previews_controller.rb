module Collavre
  module Creatives
    class PptPreviewsController < Collavre::ApplicationController
      allow_unauthenticated_access
      before_action :resume_session
      before_action :enforce_creatives_login_policy

      def show
        creative = Creative.find(params[:creative_id])
        return head :forbidden unless creative.has_permission?(Current.user, :read)

        attachment = creative.files.find(params[:id])
        return head :not_found unless attachment.filename.extension.downcase == "pptx"

        response.headers["Cache-Control"] = "private, no-store"
        @slides = PptPreview.slides(attachment.blob)
        render layout: "collavre/slide"
      rescue PptRenderer::InvalidArchive, Zip::Error, Nokogiri::XML::SyntaxError
        render plain: t("collavre.ppt_viewer.invalid"), status: :unprocessable_entity
      end

      private

      def enforce_creatives_login_policy
        require_authentication if SystemSetting.creatives_login_required?
      end
    end
  end
end
