# frozen_string_literal: true

module Collavre
  module Onboarding
    # Match the same creative and trigger-comment contexts that defer cleanup.
    class TaskCleanup
      def self.call(task)
        payload = task.trigger_event_payload
        comment = payload.is_a?(Hash) ? payload["comment"] : nil
        comment_creative_id = Comment.where(id: comment["id"]).pick(:creative_id) if comment.is_a?(Hash)
        sessions = Creative.where(id: [ task.creative_id, comment_creative_id ]).filter_map do |creative|
          next unless Ownership.owned?(creative)

          onboarding = Ownership.metadata(creative)
          next unless onboarding["cleanup_pending"] || creative.user.onboarding_completed_at?

          [ creative.user_id, onboarding.fetch("session_id") ]
        end
        sessions.uniq.each { |user_id, session_id| OnboardingCleanupJob.perform_later(user_id, session_id) }
      end
    end
  end
end
