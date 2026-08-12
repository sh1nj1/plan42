# frozen_string_literal: true

module Collavre
  module Onboarding
    class CompletionService
      def initialize(user:)
        @user = user
      end

      def call(defer_pending_agent_cleanup: false)
        session = Session.for_user(user)
        # The session id, not current tree position, is the ownership boundary.
        # This keeps moved practice items from becoming permanent clutter. If
        # the root was deleted, every remaining tagged item is orphaned and
        # must be removed before onboarding can be reset or completed.
        session_id = session&.session_id
        owned = session_items(session_id)
        session_id ||= session_id_from(owned)
        if defer_pending_agent_cleanup && session_id.present? && pending_agent_turn?(owned)
          mark_deferred_cleanup!(owned)
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

      def session_id_from(owned)
        session_ids = owned.filter_map { |creative| creative.data&.dig("onboarding", "session_id") }.uniq
        session_ids.first if session_ids.one?
      end

      def pending_agent_turn?(owned)
        comment_ids = Comment.where(creative_id: owned).pluck(:id)
        return false if comment_ids.empty?

        # Check the queue before Tasks. An AiAgentJob can hand off to a Task
        # between these checks; querying the durable queued job first ensures
        # the subsequent Task query sees that handoff rather than missing both.
        queued_agent_job_for_comments?(comment_ids) || active_task_for_comments?(comment_ids)
      end

      # This belongs to the retiring session rather than the user. Resetting
      # onboarding immediately starts another session and clears the user's
      # completion timestamp, while the old agent turn still needs to trigger
      # its one final cleanup after the bounded retry window.
      def mark_deferred_cleanup!(owned)
        owned.each do |creative|
          onboarding = creative.data.fetch("onboarding", {}).deep_dup
          next if onboarding["cleanup_pending"]

          creative.update!(data: creative.data.merge("onboarding" => onboarding.merge("cleanup_pending" => true)))
        end
      end

      def active_task_for_comments?(comment_ids)
        Task.where(status: Task::ACTIVE_STATUSES).find_each.any? do |task|
          comment_ids.include?(task.trigger_event_payload&.dig("comment", "id").to_i)
        end
      end

      # A direct dispatch creates its Task only when AiAgentJob starts. Check
      # durable Solid Queue entries as well, otherwise finishing onboarding can
      # delete the triggering comment while that job is merely waiting to run.
      def queued_agent_job_for_comments?(comment_ids)
        return false unless defined?(SolidQueue::Job)

        SolidQueue::Job.where(class_name: AiAgentJob.name, finished_at: nil).find_each.any? do |job|
          comment_ids.include?(queued_comment_id(job))
        end
      end

      def queued_comment_id(job)
        queued_job = ActiveJob::Base.deserialize(job.arguments)
        queued_job.send(:deserialize_arguments_if_needed)
        context = queued_job.arguments.last
        context.is_a?(Hash) ? context.dig("comment", "id").to_i : 0
      rescue ActiveJob::DeserializationError, KeyError, TypeError
        0
      end

      def destroy_items!(owned)
        owned.sort_by { |creative| -creative.ancestors.count }.each(&:destroy!)
      end
    end
  end
end
