# frozen_string_literal: true

module Collavre
  class CommentSnapshotRestoreService
    class RestoreError < StandardError; end

    def initialize(snapshot:, user:)
      @snapshot = snapshot
      @user = user
    end

    def call
      ActiveRecord::Base.transaction do
        # Lock the snapshot row to prevent concurrent restore (P2 fix)
        locked_snapshot = CommentSnapshot.lock.find(@snapshot.id)

        if locked_snapshot.restored_at.present?
          raise RestoreError, I18n.t("collavre.comment_snapshots.already_restored")
        end

        validate_permission!

        # Build a mapping from old comment IDs to new comments for quoted_comment_id restoration
        old_id_to_new = {}

        # First pass: recreate all comments without quoted_comment_id
        recreated = locked_snapshot.comments_data.map do |data|
          comment = Comment.create!(
            creative_id: locked_snapshot.creative_id,
            user_id: data["user_id"],
            topic_id: data["topic_id"],
            content: data["content"],
            private: data["private"] || false,
            quoted_text: data["quoted_text"],
            review_type: data["review_type"],
            skip_default_user: true
          )
          # Re-attach images if blob IDs were preserved in the snapshot
          if data["image_blob_ids"].present?
            blobs = ActiveStorage::Blob.where(id: data["image_blob_ids"])
            blobs.each { |blob| comment.images.attach(blob) }
          end
          old_id_to_new[data["id"]] = comment
          comment
        end

        # Second pass: restore quoted_comment_id for comments that reference other restored comments
        locked_snapshot.comments_data.each do |data|
          next unless data["quoted_comment_id"].present?

          new_comment = old_id_to_new[data["id"]]
          quoted_new = old_id_to_new[data["quoted_comment_id"]]
          new_comment.update_column(:quoted_comment_id, quoted_new.id) if quoted_new
        end

        # Delete the result comment (the AI summary/merged comment)
        # Use nullify + delete to avoid cascading destruction of quoting_comments (P1 fix)
        if locked_snapshot.result_comment
          result = locked_snapshot.result_comment
          # Detach any comments that quote this result so they aren't cascade-deleted
          result.quoting_comments.update_all(quoted_comment_id: nil) # rubocop:disable Rails/SkipsModelValidations
          result.destroy
        end

        # Mark snapshot as restored
        locked_snapshot.update!(restored_at: Time.current)

        recreated
      end
    end

    private

    def validate_permission!
      creative = @snapshot.creative
      unless creative.has_permission?(@user, :write)
        raise RestoreError, I18n.t("collavre.comment_snapshots.not_authorized")
      end
    end
  end
end
