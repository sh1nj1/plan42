# frozen_string_literal: true

module CollavreLinear
  # Pushes a local edit of a Collavre::Comment to its mirrored Linear comment.
  #
  #   CollavreLinear::OutboundCommentUpdateJob.perform_later(comment.id)
  #
  # No-op when the comment (or its CommentLink) is gone: a delete may have raced
  # ahead, and the delete job owns tearing down the Linear comment.
  class OutboundCommentUpdateJob < ApplicationJob
    queue_as :default

    retry_on CollavreLinear::Client::Error, wait: :polynomially_longer, attempts: 5

    def perform(comment_id)
      comment = ::Collavre::Comment.find(comment_id)

      comment_link = CollavreLinear::CommentLink.find_by(comment_id: comment.id)
      return unless comment_link

      # Re-check visibility at run time: the comment may have been made private
      # or moved out of Main between enqueue and now. The observer enqueues a
      # delete for that change, but with multiple workers this update could run
      # first and leak the now-hidden body. The delete job owns teardown; no-op.
      return unless CollavreLinear::CommentSyncability.syncable?(comment)

      account = comment_link.issue_link.project_link.account
      return unless account

      result = CollavreLinear::Client.new(account).update_comment(
        id:   comment_link.linear_comment_id,
        body: CollavreLinear::CommentFormatter.outbound_body(comment)
      )

      # Advance the synced baseline so the echo of this edit (and any stale echo
      # of an earlier body) is recognised as ours by the inbound applier.
      comment_link.update!(remote_updated_at: result[:updatedAt]) if result[:updatedAt].present?
    rescue ActiveRecord::RecordNotFound
      Rails.logger.info(
        "[CollavreLinear::OutboundCommentUpdateJob] Comment #{comment_id} not found; skipping"
      )
    end
  end
end
