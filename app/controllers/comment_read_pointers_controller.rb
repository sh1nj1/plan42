class CommentReadPointersController < ApplicationController
  def update
    creative = Creative.find(params[:creative_id]).effective_origin
    last_id = creative.comments.maximum(:id)
    pointer = CommentReadPointer.find_or_initialize_by(user: Current.user, creative: creative)
    pointer.last_read_comment_id = last_id
    pointer.save!
    mark_inbox_items_read(creative, last_id)
    Comment.broadcast_badge(creative, Current.user)
    render json: { success: true }
  end

  private

  def mark_inbox_items_read(creative, last_comment_id)
    return unless last_comment_id

    base_scope = InboxItem.where(owner: Current.user, state: "new")
                          .where(message_key: [ "inbox.comment_added", "inbox.user_mentioned" ])

    with_creative = base_scope.where(creative: creative)
                              .where("comment_id IS NULL OR comment_id <= ?", last_comment_id)

    legacy = base_scope.where(creative_id: nil)
                       .where("link LIKE ?", "%/creatives/#{creative.id}/%")

    ids = (with_creative.pluck(:id) + legacy.pluck(:id)).uniq
    return if ids.empty?

    InboxItem.transaction do
      InboxItem.where(id: ids).where.not(state: "read").find_each do |item|
        item.update!(state: "read")
      end
    end
  end
end
