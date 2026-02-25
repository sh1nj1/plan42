# frozen_string_literal: true

module Collavre
  module Comments
    class VersionsController < ApplicationController
      before_action :set_creative
      before_action :set_comment

      def index
        versions = @comment.comment_versions.order(:version_number).map do |v|
          {
            id: v.id,
            version_number: v.version_number,
            content: v.content,
            created_at: v.created_at.iso8601
          }
        end

        render json: {
          versions: versions,
          current_content: @comment.content,
          selected_version_id: @comment.selected_version_id,
          total: versions.size + 1
        }
      end

      def select
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        version = @comment.comment_versions.find(params[:id])
        @comment.update!(selected_version_id: version.id)

        render json: { selected_version_id: version.id }
      end

      def deselect
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        @comment.update!(selected_version_id: nil)
        render json: { selected_version_id: nil }
      end

      def destroy
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        version = @comment.comment_versions.find(params[:id])
        @comment.update!(selected_version_id: nil) if @comment.selected_version_id == version.id
        version.destroy!
        head :no_content
      end

      private

      def set_creative
        @creative = Creative.find(params[:creative_id]).effective_origin
      end

      def set_comment
        @comment = @creative.comments
                             .where(
                               "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
                               false,
                               Current.user.id,
                               Current.user.id
                             )
                             .find(params[:comment_id])
      end
    end
  end
end
