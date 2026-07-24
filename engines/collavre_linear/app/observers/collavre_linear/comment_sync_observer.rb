# frozen_string_literal: true

module CollavreLinear
  # Auto-triggers an outbound Linear comment sync when a human posts a chat
  # message in the Main topic of a creative that is linked to a Linear issue.
  #
  # Mixed into Collavre::Comment via the engine's `to_prepare` block:
  #
  #   Collavre::Comment.include CollavreLinear::CommentSyncObserver
  #
  # Mirrors CreativeSyncObserver: the transient `skip_linear_sync` flag lets the
  # inbound applier suppress the echo when it mirrors a Linear comment locally
  # (otherwise the mirrored comment would bounce straight back out to Linear).
  module CommentSyncObserver
    extend ActiveSupport::Concern

    included do
      # Transient, per-record suppression flag set by the inbound applier on the
      # comment it mirrors from Linear so this after_commit does not echo it back.
      attr_accessor :skip_linear_sync

      after_create_commit  :enqueue_linear_comment_sync
      after_update_commit  :enqueue_linear_comment_update
      after_destroy_commit :enqueue_linear_comment_delete
    end

    private

    def enqueue_linear_comment_sync
      return unless linear_syncable_comment?

      CollavreLinear::OutboundCommentSyncJob.perform_later(id)
    rescue StandardError => e
      log_enqueue_failure("sync", e)
    end

    # Propagate a local edit to Linear. A single core update can change content,
    # `private`, and `topic_id` together, so re-check syncability: if the comment
    # turned private or moved out of Main, remove its Linear mirror rather than
    # pushing the now-hidden body outward. `skip_linear_sync` suppresses the echo
    # when the inbound applier rewrites content from Linear.
    def enqueue_linear_comment_update
      return if skip_linear_sync

      comment_link = CollavreLinear::CommentLink.find_by(comment_id: id)

      unless comment_link
        # No mirror: either never synced, or a prior update tore it down when the
        # comment went private / left Main. If it is syncable again, recreate the
        # mirror so re-entering visibility doesn't leave it permanently off Linear.
        # The sync job locks the IssueLink and re-checks CommentLink existence, so
        # this can't duplicate a mirror the create path is still building.
        CollavreLinear::OutboundCommentSyncJob.perform_later(id) if linear_syncable_comment?
        return
      end

      unless linear_syncable_comment?
        CollavreLinear::OutboundCommentDeleteJob.perform_later(comment_link.id)
        return
      end

      return unless saved_change_to_content?

      CollavreLinear::OutboundCommentUpdateJob.perform_later(id)
    rescue StandardError => e
      log_enqueue_failure("update", e)
    end

    # Propagate a local deletion to Linear. The comment row is gone by the time
    # this after-commit runs, so the CommentLink (not cascade-deleted — no FK on
    # comment_id) is the only handle on the Linear comment id; the job consumes it.
    def enqueue_linear_comment_delete
      return if skip_linear_sync

      comment_link = CollavreLinear::CommentLink.find_by(comment_id: id)
      return unless comment_link

      CollavreLinear::OutboundCommentDeleteJob.perform_later(comment_link.id)
    rescue StandardError => e
      log_enqueue_failure("delete", e)
    end

    def log_enqueue_failure(kind, error)
      # Never let sync scheduling break the host transaction's commit callbacks.
      Rails.logger.error(
        "[CollavreLinear::CommentSyncObserver] failed to enqueue comment #{kind} for " \
        "comment #{id}: #{error.class}: #{error.message}"
      )
    end

    # Delegates to the shared predicate so the observer and the outbound update
    # job (which re-checks at run time) can never diverge on what is syncable.
    def linear_syncable_comment?
      CollavreLinear::CommentSyncability.syncable?(self)
    end
  end
end
