# frozen_string_literal: true

module Collavre
  module Comments
    module CommentScoping
      extend ActiveSupport::Concern

      private

      def set_creative
        @creative = Creative.find(params[:creative_id]).effective_origin
        unless @creative.has_permission?(Current.user, :read)
          render json: { error: I18n.t("collavre.creatives.errors.no_permission") }, status: :forbidden
        end
      end

      def set_comment
        comment_id = params[:comment_id] || params[:id]
        @comment = @creative.comments.visible_to(Current.user).find(comment_id)
      end
    end
  end
end
