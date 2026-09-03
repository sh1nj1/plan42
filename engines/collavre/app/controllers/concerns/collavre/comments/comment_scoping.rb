# frozen_string_literal: true

module Collavre
  module Comments
    module CommentScoping
      extend ActiveSupport::Concern

      private

      def set_creative
        @requested_creative = Creative.find(params[:creative_id])
        @creative = @requested_creative.effective_origin
        readable_ids = Creatives::PermissionFilter.new(user: Current.user).readable_ids([ @requested_creative.id ])
        unless readable_ids.include?(@requested_creative.id)
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
