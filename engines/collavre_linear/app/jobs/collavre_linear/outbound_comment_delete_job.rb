# frozen_string_literal: true

module CollavreLinear
  # Deletes the mirrored Linear comment when a Collavre::Comment is destroyed.
  #
  #   CollavreLinear::OutboundCommentDeleteJob.perform_later(comment_link.id)
  #
  # Keyed on the CommentLink id (not the comment id): the local comment is already
  # hard-deleted by the time this runs, so the link is the only surviving handle
  # on the Linear comment id. Idempotent: a re-run after the link is torn down
  # finds nothing and does nothing.
  class OutboundCommentDeleteJob < ApplicationJob
    queue_as :default

    retry_on CollavreLinear::Client::Error, wait: :polynomially_longer, attempts: 5

    def perform(comment_link_id)
      comment_link = CollavreLinear::CommentLink.find_by(id: comment_link_id)
      return unless comment_link

      account = comment_link.issue_link.project_link.account
      return unless account

      comment_link.with_lock do
        # This delete was enqueued because the comment went private / left Main.
        # If it became visible again before the job ran, its CommentLink still
        # exists and the observer's update path enqueues NO recreate (only
        # private/topic_id changed, not content), so tearing the mirror down now
        # would strand the re-visible comment off Linear until its next edit.
        # Re-check under the lock (mirrors the update job): keep the mirror when
        # the comment is syncable again. A hard-deleted comment is gone → not
        # syncable → teardown proceeds as before.
        comment = ::Collavre::Comment.find_by(id: comment_link.comment_id)
        return if comment && CollavreLinear::CommentSyncability.syncable?(comment)

        CollavreLinear::Client.new(account).delete_comment(comment_link.linear_comment_id)
        comment_link.destroy
      end
    end
  end
end
