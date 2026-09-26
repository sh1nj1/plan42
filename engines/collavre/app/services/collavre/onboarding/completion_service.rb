# frozen_string_literal: true

module Collavre
  module Onboarding
    class CompletionService
      def initialize(user:)
        @user = user
      end

      def call(session_id: nil, defer_pending_agent_cleanup: false)
        session = Session.for_user(user)
        return false if session_id.present? && session&.session_id != session_id

        # The session id, not current tree position, is the ownership boundary.
        # This keeps moved practice items from becoming permanent clutter. If
        # the root was deleted, every remaining tagged item is orphaned and
        # must be removed before onboarding can be reset or completed.
        resolved_session_id = session_id || session&.session_id
        session_item_groups(resolved_session_id).each do |owned_session_id, owned|
          if defer_pending_agent_cleanup && pending_agent_turn?(owned)
            mark_deferred_cleanup!(owned)
            OnboardingCleanupJob.perform_later(user.id, owned_session_id)
          else
            destroy_items!(owned)
          end
        end
        user.update!(onboarding_completed_at: Time.current)
        true
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
          next false unless Ownership.owned?(creative)

          creative_session_id = Ownership.metadata(creative)["session_id"]
          creative_session_id.present? && (session_id.nil? || creative_session_id == session_id)
        end
      end

      def session_item_groups(session_id)
        session_items(session_id).group_by do |creative|
          creative.data.dig("onboarding", "session_id")
        end
      end

      def pending_agent_turn?(owned)
        return false if owned.empty?

        comment_ids = Comment.where(creative_id: owned).pluck(:id)
        creative_ids = owned.map(&:id)

        # Check the queue before Tasks. An AiAgentJob can hand off to a Task
        # between these checks; querying the durable queued job first ensures
        # the subsequent Task query sees that handoff rather than missing both.
        queued_agent_job_for_comments?(comment_ids, creative_ids) || active_task_for_comments?(comment_ids, creative_ids)
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

      def active_task_for_comments?(comment_ids, creative_ids)
        return true if Task.where(status: Task::ACTIVE_STATUSES, creative_id: creative_ids).exists?
        return false if comment_ids.empty?

        PayloadScope.matching(Task.where(status: Task::ACTIVE_STATUSES), "trigger_event_payload",
                              %w[comment id], comment_ids).exists?
      end

      # A direct dispatch creates its Task only when AiAgentJob starts. Check
      # durable Solid Queue entries as well, otherwise finishing onboarding can
      # delete the triggering comment while that job is merely waiting to run.
      def queued_agent_job_for_comments?(comment_ids, creative_ids)
        return false unless defined?(SolidQueue::Job)

        jobs = SolidQueue::Job.where(class_name: AiAgentJob.name, finished_at: nil)
        by_comment = PayloadScope.matching(jobs, "arguments", %w[arguments 2 comment id], comment_ids)
        by_creative = PayloadScope.matching(jobs, "arguments", %w[arguments 2 creative id], creative_ids)
        by_comment.or(by_creative).exists?
      end

      def destroy_items!(owned)
        Creative.transaction do
          owned.sort_by { |creative| -creative.ancestors.count }.each do |creative|
            # Preserve actual children, never a linked origin's visible subtree.
            Creative.where(parent_id: creative.id).each do |child|
              child.skip_drop_trigger_on_move = true
              child.update!(parent: creative.parent)
            end
            creative.destroy!
          end
        end
      end
    end
  end
end
