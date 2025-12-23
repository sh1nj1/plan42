class CommentReaction < ApplicationRecord
  belongs_to :comment
  belongs_to :user

  validates :emoji, presence: true, length: { maximum: 16 }
  validates :user_id, uniqueness: { scope: [ :comment_id, :emoji ] }

  after_commit :broadcast_comment_update, on: [ :create, :destroy ]

  private

  def broadcast_comment_update
    return if comment.private?

    comment_record = Comment.with_attached_images.includes(:comment_reactions).find(comment_id)
    Turbo::StreamsChannel.broadcast_update_to(
      [ comment_record.creative, :comments ],
      target: ActionView::RecordIdentifier.dom_id(comment_record),
      partial: "comments/comment",
      locals: { comment: comment_record }
    )
  end
end
