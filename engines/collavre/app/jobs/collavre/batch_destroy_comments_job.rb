module Collavre
  # Destroys a chat selection the request already hid (deleting_at), so the
  # user is not kept waiting on every comment's destroy callbacks.
  class BatchDestroyCommentsJob < ApplicationJob
    queue_as :default

    def perform(comment_ids)
      comments = Comment.where(id: comment_ids).where.not(deleting_at: nil).to_a
      destroyed_ids = Comment.destroy_in_batch(comments).map(&:id)

      # A destroy its callbacks refused leaves the comment in place: show it
      # again rather than keep it hidden forever.
      kept_ids = comments.map(&:id) - destroyed_ids
      Comment.where(id: kept_ids).update_all(deleting_at: nil) if kept_ids.any?
    end
  end
end
