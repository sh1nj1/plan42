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

    # Propagate a local edit to Linear. Gated on an existing CommentLink: only a
    # comment that already reached Linear (as a real human Main-topic post) has
    # one, so this needs no re-run of the full syncability check. `skip_linear_sync`
    # suppresses the echo when the inbound applier rewrites content from Linear.
    def enqueue_linear_comment_update
      return if skip_linear_sync
      return unless saved_change_to_content?
      return unless CollavreLinear::CommentLink.exists?(comment_id: id)

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

    # Only mirror real human chat posted in the Main topic of a linked creative.
    # Excludes: inbound echoes; private notes; system/waiting notices (no user);
    # AI agent turns — their comment is created as a "..." streaming placeholder
    # and mutated in place, so an after_create hook would post "..." and never
    # settle; the placeholder itself; and creatives with no Linear issue.
    def linear_syncable_comment?
      return false if skip_linear_sync
      return false if private?
      return false if user_id.nil?
      return false if user&.ai_user?
      return false if content.blank?
      return false if content == ::Collavre::Comment::STREAMING_PLACEHOLDER_CONTENT
      return false unless topic&.name == ::Collavre::Creative::MAIN_TOPIC_NAME
      return false unless creative

      creative.linear_issue_links.exists?
    end
  end
end
