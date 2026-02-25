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
          total: versions.size + 1
        }
      end

      def destroy
        version = @comment.comment_versions.find(params[:id])
        version.destroy!
        head :no_content
      end

      private

      def set_creative
        @creative = Creative.find(params[:creative_id]).effective_origin
      end

      def set_comment
        @comment = @creative.comments.find(params[:comment_id])
      end
    end
  end
end
