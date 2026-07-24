# frozen_string_literal: true

module Collavre
  # Recomputes and rebroadcasts the per-participant comment badges of a creative.
  #
  # The arithmetic is O(comment history) x O(participants): a total count, an
  # unread count per distinct read watermark, and a private count per user. Run
  # inline from Comment's after_commit it made writing a message cost more the
  # longer the conversation was — and an inbox notification wrote a second
  # comment into an inbox creative, paying the same price again over that
  # inbox's own history.
  #
  # Badges are eventually-consistent UI: the recipient already got the comment
  # itself over its own Turbo stream, so recounting a beat later is invisible.
  class CommentBadgesBroadcastJob < ApplicationJob
    queue_as :default
    discard_on ActiveJob::DeserializationError

    def perform(creative_id)
      creative = Creative.find_by(id: creative_id)
      # Deleting a creative destroys its comments, so the enqueued job can
      # outlive its subject. Nothing to recount, and nobody to tell.
      return unless creative

      Comment.broadcast_badges(creative)
    end
  end
end
