# frozen_string_literal: true

module Collavre
  module Comments
    class ResendsController < ApplicationController
      include CommentScoping

      before_action :set_creative
      before_action :set_comment

      def create
        comment = CommentResendService.new(comment: @comment, user: Current.user).call
        render json: { id: comment.id, topic_id: comment.topic_id }, status: :created
      rescue CommentResendService::NotAllowed
        render json: { error: I18n.t("collavre.comments.resend_not_allowed") }, status: :forbidden
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed
        render json: { error: I18n.t("collavre.comments.resend_failed") }, status: :unprocessable_entity
      end
    end
  end
end
