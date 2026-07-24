# frozen_string_literal: true

module Collavre
  module Comments
    class SnapshotsController < ApplicationController
      include Collavre::Comments::CommentScoping

      before_action :set_creative
      before_action :set_snapshot, only: [ :restore ]

      # GET /creatives/:creative_id/comments/snapshots
      def index
        snapshots = @creative.comment_snapshots
          .restorable
          .order(created_at: :desc)

        render json: snapshots.map { |s| snapshot_json(s) }
      end

      # POST /creatives/:creative_id/comments/snapshots/:id/restore
      def restore
        service = CommentSnapshotRestoreService.new(snapshot: @snapshot, user: Current.user)
        recreated = service.call
        render json: {
          message: I18n.t("collavre.comment_snapshots.restored"),
          count: recreated.size
        }
      rescue CommentSnapshotRestoreService::RestoreError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_snapshot
        @snapshot = @creative.comment_snapshots.find(params[:id])
      end

      def snapshot_json(snapshot)
        {
          id: snapshot.id,
          operation: snapshot.operation,
          comment_count: snapshot.comment_count,
          created_at: snapshot.created_at,
          result_comment_id: snapshot.result_comment_id,
          restorable: snapshot.restorable?
        }
      end
    end
  end
end
