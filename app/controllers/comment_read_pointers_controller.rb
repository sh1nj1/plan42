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
    comment = creative.comments.find_by(id: comment_id)
    return if comment.nil? || comment.private?

    # Fetch all users who have this comment as their last read comment
    users = CommentReadPointer.where(creative: creative, last_read_comment_id: comment_id)
                              .includes(user: { avatar_attachment: :blob })
                              .map(&:user)

    Turbo::StreamsChannel.broadcast_update_to(
      [ creative, :comments ],
      target: "read_receipts_comment_#{comment_id}",
      partial: "comments/read_receipts",
      locals: { read_by_users: users }
    )
  end

  def mark_inbox_items_read(creative, last_comment_id)
    return unless last_comment_id

    base_scope = InboxItem.where(owner: Current.user, state: "new")
                          .where(message_key: [ "inbox.comment_added", "inbox.user_mentioned" ])

    with_creative = base_scope.where(creative: creative)
                              .where("comment_id IS NULL OR comment_id <= ?", last_comment_id)

    ids = with_creative.pluck(:id)
    return if ids.empty?

    InboxItem.transaction do
      InboxItem.where(id: ids).where.not(state: "read").find_each do |item|
        item.update!(state: "read")
      end
    end
  end
end
