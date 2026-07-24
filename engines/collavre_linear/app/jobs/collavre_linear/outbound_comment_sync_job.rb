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

      # Captured inside the lock so the self-echo rescue can reconcile AFTER the
      # lock's transaction rolls back — rescuing the unique violation inside the
      # `with_lock` transaction would poison it (Postgres aborts the whole tx).
      posted = nil

      begin
        issue_link.with_lock do
          # Re-check under the lock: an inbound mirror or a prior run may have
          # linked this comment already. One Collavre comment -> one Linear comment.
          return if CollavreLinear::CommentLink.exists?(comment_id: comment.id)

          # Re-check visibility at run time: the comment was public/Main when the
          # observer enqueued this create, but may have been made private or moved
          # out of Main since. No CommentLink exists yet, so the observer cannot
          # enqueue a delete for that change — posting the now-hidden body would
          # leak it. Same predicate the update job re-runs; here it must no-op.
          return unless CollavreLinear::CommentSyncability.syncable?(comment)

          posted = CollavreLinear::Client.new(account).create_comment(
            issue_id: issue_link.linear_issue_id,
            body:     CollavreLinear::CommentFormatter.outbound_body(comment)
          )
          return if posted[:id].blank?

          # Record Linear's updatedAt for this version so the inbound applier can
          # recognise the create webhook (and any stale echo of it) as our own by
          # timestamp rather than by comparing against the mutable local body.
          CollavreLinear::CommentLink.create!(
            comment_id:        comment.id,
            linear_comment_id: posted[:id],
            issue_link:        issue_link,
            remote_updated_at: posted[:updatedAt]
          )
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Self-echo race: the inbound create webhook for the comment we just posted
        # landed first (app_actor_id is nil, so EchoGuard can't drop it), mirrored
        # it locally, and grabbed the unique linear_comment_id. Adopt that link onto
        # our original comment and drop the duplicate mirror — otherwise the comment
        # is double-represented and our original stays unlinked, so a later edit
        # re-posts it. Mirrors CreativeExporter#reconcile_self_echo!. Any other
        # validation error must still surface.
        raise if e.is_a?(ActiveRecord::RecordInvalid) && !duplicate_comment_link_error?(e)

        reconcile_comment_self_echo!(comment, issue_link, posted)
      end
    rescue ActiveRecord::RecordNotFound
      Rails.logger.info(
        "[CollavreLinear::OutboundCommentSyncJob] Comment #{comment_id} not found; skipping"
      )
    end

    private

    # True when the failure is exactly the CommentLink linear_comment_id
    # uniqueness collision (the self-echo race), not some other invalid record.
    def duplicate_comment_link_error?(error)
      record = error.record
      record.is_a?(CollavreLinear::CommentLink) &&
        record.errors.of_kind?(:linear_comment_id, :taken)
    end

    def reconcile_comment_self_echo!(comment, issue_link, posted)
      linear_comment_id = posted && posted[:id]
      return if linear_comment_id.blank?

      existing = CollavreLinear::CommentLink.find_by(linear_comment_id: linear_comment_id)
      return unless existing

      mirror = ::Collavre::Comment.find_by(id: existing.comment_id)
      CollavreLinear::CommentLink.transaction do
        existing.update!(
          comment_id:        comment.id,
          issue_link:        issue_link,
          remote_updated_at: posted[:updatedAt]
        )

        # Remove the echo duplicate. The link was reassigned above, so the mirror
        # no longer owns it; skip_linear_sync stops the destroy observer from
        # posting a Linear delete for the comment we just created.
        if mirror && mirror.id != comment.id
          mirror.skip_linear_sync = true
          mirror.destroy!
        end
      end
    end
  end
end
