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

        # Save current content as a version if not already versioned
        unless @comment.comment_versions.exists?(content: @comment.content)
          @comment.comment_versions.create!(
            content: @comment.content,
            version_number: @comment.next_version_number
          )
        end

        # Update pointer AND content
        @comment.update!(selected_version_id: version.id, content: version.content)

        render json: { selected_version_id: version.id, content: version.content }
      end

      def deselect
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        latest_version = @comment.comment_versions.order(:version_number).last
        new_content = latest_version&.content || @comment.content
        @comment.update!(selected_version_id: nil, content: new_content)
        render json: { selected_version_id: nil, content: new_content }
      end

      def destroy
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        version = @comment.comment_versions.find(params[:id])
        was_selected = @comment.selected_version_id == version.id
        version.destroy!

        if was_selected
          # Roll back to the latest remaining version or the newest version's content
          latest = @comment.comment_versions.order(:version_number).last
          if latest
            @comment.update!(selected_version_id: latest.id, content: latest.content)
          else
            @comment.update!(selected_version_id: nil)
          end
        end

        remaining = @comment.comment_versions.count
        render json: {
          selected_version_id: @comment.selected_version_id,
          content: @comment.content,
          total: remaining + 1
        }
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
