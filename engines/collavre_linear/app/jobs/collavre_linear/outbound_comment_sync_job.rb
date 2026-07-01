# frozen_string_literal: true

module CollavreLinear
  # Pushes a single Collavre::Comment to its linked Linear issue as a comment.
  #
  #   CollavreLinear::OutboundCommentSyncJob.perform_later(comment.id)
  #
  # Idempotent: the IssueLink row is locked and the CommentLink existence is
  # re-checked inside the lock, so concurrent performs (or a duplicate enqueue)
  # never post the same chat message to Linear twice.
  class OutboundCommentSyncJob < ApplicationJob
    queue_as :default

    retry_on CollavreLinear::Client::Error, wait: :polynomially_longer, attempts: 5

    def perform(comment_id)
      comment = ::Collavre::Comment.find(comment_id)

      issue_link = comment.creative&.linear_issue_links&.first
      return if issue_link&.linear_issue_id.blank?

      account = issue_link.project_link.account
      return unless account

      issue_link.with_lock do
        # Re-check under the lock: an inbound mirror or a prior run may have
        # linked this comment already. One Collavre comment -> one Linear comment.
        return if CollavreLinear::CommentLink.exists?(comment_id: comment.id)

        result = CollavreLinear::Client.new(account).create_comment(
          issue_id: issue_link.linear_issue_id,
          body:     CollavreLinear::CommentFormatter.outbound_body(comment)
        )

        linear_comment_id = result[:id]
        return if linear_comment_id.blank?

        # Record Linear's updatedAt for this version so the inbound applier can
        # recognise the create webhook (and any stale echo of it) as our own by
        # timestamp rather than by comparing against the mutable local body.
        CollavreLinear::CommentLink.create!(
          comment_id:        comment.id,
          linear_comment_id: linear_comment_id,
          issue_link:        issue_link,
          remote_updated_at: result[:updatedAt]
        )
      end
    rescue ActiveRecord::RecordNotFound
      Rails.logger.info(
        "[CollavreLinear::OutboundCommentSyncJob] Comment #{comment_id} not found; skipping"
      )
    end
  end
end
