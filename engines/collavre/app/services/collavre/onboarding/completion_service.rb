# frozen_string_literal: true

module Collavre
  module Onboarding
    class CompletionService
      def initialize(user:)
        @user = user
      end

      def call(defer_pending_agent_cleanup: false)
        session = Session.for_user(user)
        session_id = session&.session_id
        # The session id, not current tree position, is the ownership boundary.
        # This keeps moved practice items from becoming permanent clutter. If
        # the root was deleted, every remaining tagged item is orphaned and
        # must be removed before onboarding can be reset or completed.
        owned = session_items(session_id)
        if defer_pending_agent_cleanup && session_id.present? && pending_agent_turn?(owned)
          OnboardingCleanupJob.perform_later(user.id, session_id)
        else
          destroy_items!(owned)
        end
        user.update!(onboarding_completed_at: Time.current)
      end

      # A deferred cleanup is scoped to the session that was completed, so a
      # reset that starts another guide cannot remove the new session later.
      def clean_up_when_agent_turn_settles(session_id)
        owned = session_items(session_id)
        return false if pending_agent_turn?(owned)

        destroy_items!(owned)
        true
      end

      private

      attr_reader :user

      def session_items(session_id)
        user.creatives.select do |creative|
          creative_session_id = creative.data&.dig("onboarding", "session_id")
          creative_session_id.present? && (session_id.nil? || creative_session_id == session_id)
        end
      end

      def pending_agent_turn?(owned)
        comment_ids = Comment.where(creative_id: owned).pluck(:id)
        return false if comment_ids.empty?

        Task.where(status: Task::ACTIVE_STATUSES).find_each.any? do |task|
          comment_ids.include?(task.trigger_event_payload&.dig("comment", "id").to_i)
        end
      end

      def destroy_items!(owned)
        owned.sort_by { |creative| -creative.ancestors.count }.each(&:destroy!)
      end
    end
  end
end
