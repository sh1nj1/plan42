module Collavre
  class CommentReadPointersController < ApplicationController
    def update
      creative = Creative.find(params[:creative_id]).effective_origin
      last_id = creative.comments.where("comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?", false, Current.user.id, Current.user.id).maximum(:id)
      pointer = CommentReadPointer.find_or_initialize_by(user: Current.user, creative: creative)

      previous_last_read_id = pointer.last_read_comment_id
      pointer.last_read_comment_id = last_id
      pointer.save!

      mark_inbox_items_read(creative, last_id)
      Comment.broadcast_badge(creative, Current.user)

      if previous_last_read_id && previous_last_read_id != last_id
        broadcast_read_receipts(creative, previous_last_read_id)
      end
      broadcast_read_receipts(creative, last_id)

      render json: { success: true }
    end

    private

    def broadcast_read_receipts(creative, comment_id)
      return unless comment_id

      # We map to the nearest PUBLIC comment to avoid leaking the existence/ID of private comments
      # via the public action cable channel.
      # Trade-off: Private-only threads (with no preceding public comment) will not get real-time read updates.
      effective_id = find_nearest_public_comment_id(creative, comment_id)
      return unless effective_id

      users = fetch_users_on_effective_id(creative, effective_id)

      present_user_ids = CommentPresenceStore.list(creative.id)

      Turbo::StreamsChannel.broadcast_update_to(
        [ creative, :comments ],
        target: "read_receipts_comment_#{effective_id}",
        partial: "collavre/comments/read_receipts",
        locals: { read_by_users: users, present_user_ids: present_user_ids }
      )
    end

    def find_nearest_public_comment_id(creative, comment_id)
      creative.comments.where(private: false).where("id <= ?", comment_id).maximum(:id)
    end

    def fetch_users_on_effective_id(creative, effective_id)
      next_public_id = creative.comments.where(private: false).where("id > ?", effective_id).minimum(:id)

      query = CommentReadPointer.where(creative: creative)
                                .where("last_read_comment_id >= ?", effective_id)

      query = query.where("last_read_comment_id < ?", next_public_id) if next_public_id

      query.includes(user: { avatar_attachment: :blob }).map(&:user)
    end

    # No-op: inbox notifications are now comments on the user's inbox creative.
    # Reading comments on a creative updates the CommentReadPointer, which
    # automatically handles the unread count for the inbox badge.
    def mark_inbox_items_read(_creative, _last_comment_id)
      # Intentionally empty — kept for backward compatibility during transition.
    end
  end
end
