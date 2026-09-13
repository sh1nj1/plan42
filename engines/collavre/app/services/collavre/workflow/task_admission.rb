# frozen_string_literal: true

module Collavre
  module Workflow
    # Called under the existing topic-slot transaction. Never takes a chain lock.
    module TaskAdmission
      RESUMPTION_STATUSES = %w[pending queued pending_approval].freeze

      def self.duplicate_dispatch?(context, agent)
        comment_id = context&.dig("comment", "id")
        !DispatchIdentity.valid?(context, agent.id) && comment_id && Task.duplicate_running_for_comment?(agent.id, comment_id)
      end

      def self.attributes(context, agent)
        row = DispatchIdentity.admission(context, agent.id)
        row ? { workflow_execution_id: row.execution_id } : {}
      end

      def self.permitted?(context, agent)
        return true unless context&.key?("workflow_execution_id")
        row = DispatchIdentity.admission(context, agent.id)
        return false unless row
        execution = row.execution
        execution.lock! if Task.connection.transaction_open?
        return false unless execution.reload.open? && !row.task
        safety = Safety.new(row.execution)
        !safety.reason && safety.permitted?(agent)
      end

      def self.start!(task)
        return task.update!(status: "running") unless task.workflow?
        outcome = task.with_lock do
          next :duplicate unless task.status.in?(%w[pending pending_approval])
          task.workflow_execution.lock!
          if task.workflow_execution.open? || task.pending_approval?
            next :denied unless FixedAnchor.validate!(task)
            task.update!(status: "running")
            :started
          else
            task.cancel_if_active!
            :denied
          end
        end
        cleanup(task) if outcome == :denied
        outcome == :started
      end

      def self.validate_start!(task)
        return true unless task.workflow?
        outcome = task.with_lock do
          next :duplicate unless RESUMPTION_STATUSES.include?(task.status)
          next :denied unless FixedAnchor.validate!(task)
          if !task.pending_approval? && !task.workflow_execution.reload.open?
            task.cancel_if_active!(statuses: RESUMPTION_STATUSES)
            :denied
          else
            :valid
          end
        end
        cleanup(task) if outcome == :denied
        outcome == :valid
      end

      def self.reject_resumption!(task)
        denied = task.with_lock do
          next false unless RESUMPTION_STATUSES.include?(task.status)
          task.cancel_if_active!(statuses: RESUMPTION_STATUSES) if FixedAnchor.validate!(task)
          true
        end
        cleanup(task) if denied
      end

      def self.cleanup(task)
        Comment.remove_waiter_notices!(creative_id: task.creative_id, topic_id: task.topic_id, task_ids: task.id)
        Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end
    end
  end
end
