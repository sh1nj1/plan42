# frozen_string_literal: true

module Collavre
  class Comment
    # A saved comment fans out into several background jobs from its
    # after_commit callbacks (live broadcast, badge recount, notifications,
    # link preview, agent dispatch). Collect them so they reach the queue in
    # one bulk insert instead of one queue transaction each. The callbacks
    # themselves, and the moment they run, are unchanged.
    module BulkFollowUpJobs
      # Fire-and-forget jobs whose callers never read the enqueue result, so
      # they may be written at the end of the callback chain. Anything else
      # (e.g. AiAgentJob, whose dispatcher checks successfully_enqueued?) is
      # written immediately, together with whatever is pending.
      DEFERRABLE_JOBS = %w[
        Turbo::Streams::ActionBroadcastJob
        Turbo::Streams::BroadcastJob
        Turbo::Streams::BroadcastStreamJob
        Collavre::CommentBadgesBroadcastJob
        Collavre::CommentNotificationJob
        Collavre::CommentLinkPreviewJob
      ].freeze

      def committed!(...)
        Collavre::BulkJobEnqueue.collect(deferrable: DEFERRABLE_JOBS) { super }
      end
    end
  end
end
