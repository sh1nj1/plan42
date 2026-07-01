# frozen_string_literal: true

module CollavreLinear
  # Single source of truth for "may this Collavre comment be mirrored to Linear?".
  #
  # Shared by CommentSyncObserver (deciding whether to enqueue outbound work) and
  # OutboundCommentUpdateJob (re-checking at run time): a comment can be made
  # private or moved out of the Main topic AFTER an update job is enqueued, and
  # with multiple workers that update could run before the delete the observer
  # enqueues for the same visibility change — leaking the now-hidden body. Both
  # gates share this predicate so they can never drift.
  module CommentSyncability
    module_function

    # Only mirror a real, still-visible human chat post in the Main topic of a
    # creative linked to a Linear issue. Excludes: inbound echoes; private notes;
    # system/waiting notices (no user); AI agent turns (their comment starts as a
    # "..." streaming placeholder and mutates in place); the placeholder itself;
    # and comments moved out of Main or on unlinked creatives.
    def syncable?(comment)
      return false if comment.skip_linear_sync
      return false if comment.private?
      return false if comment.user_id.nil?
      return false if comment.user&.ai_user?
      return false if comment.content.blank?
      return false if comment.content == ::Collavre::Comment::STREAMING_PLACEHOLDER_CONTENT
      return false unless comment.topic&.name == ::Collavre::Creative::MAIN_TOPIC_NAME
      return false unless comment.creative

      comment.creative.linear_issue_links.exists?
    end
  end
end
