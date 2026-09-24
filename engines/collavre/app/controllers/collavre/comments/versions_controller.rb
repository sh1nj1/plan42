# frozen_string_literal: true

module Collavre
  module Comments
    class VersionsController < ApplicationController
      include Collavre::Comments::CommentScoping

      before_action :set_creative
      before_action :set_comment

      def index
        versions = @comment.comment_versions.order(:version_number).map do |v|
          {
            id: v.id,
            version_number: v.version_number,
            content: v.content,
            agent_run_options: v.agent_run_options,
            run_options_html: run_options_html(v),
            created_at: v.created_at.iso8601
          }
        end

        render json: {
          versions: versions,
          selected_version_id: @comment.selected_version_id,
          total: versions.size
        }
      end

      def select
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        version = @comment.comment_versions.find(params[:id])
        @comment.update!(version.comment_attributes)

        render json: version.comment_attributes
      end

      def destroy
        unless @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
          render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
        end

        version = @comment.comment_versions.find(params[:id])
        @comment.with_lock do
          restore_remaining_version(version) if @comment.selected_version_id == version.id
          version.destroy!
        end

        remaining = @comment.comment_versions.count
        render json: {
          selected_version_id: @comment.selected_version_id,
          content: @comment.content,
          agent_run_options: @comment.agent_run_options,
          total: remaining
        }
      end

      private

      def restore_remaining_version(version)
        latest = @comment.comment_versions.where.not(id: version.id).order(:version_number).last
        @comment.update!(latest ? latest.comment_attributes : { selected_version_id: nil })
      end

      def run_options_html(version)
        render_to_string(partial: "collavre/comments/run_options", locals: { run_options: version.agent_run_options })
      end
    end
  end
end
