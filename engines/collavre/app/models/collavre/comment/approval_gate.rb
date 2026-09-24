# frozen_string_literal: true

module Collavre
  class Comment
    module ApprovalGate
      extend ActiveSupport::Concern

      included do
        # The gate comment is the only surface that can decide its task. Once it
        # is gone (deleted, or moved out of the task's topic) nothing can approve
        # or deny, so the paused task would hold its slot forever.
        # Separate names: Rails keeps only the last *_commit registration of a method.
        after_destroy_commit :abandon_deleted_approval_gate, if: :approval_gate?
        after_update_commit :abandon_moved_approval_gate, if: :approval_gate_moved?
      end

      def approval_gate?
        approval_gate_action.present?
      end

      def approval_gate_denied?
        approval_gate_action&.dig("decision", "decision") == "denied"
      end

      def approval_gate_reason
        approval_gate_action&.dig("decision", "reason")
      end

      def approval_gate_action
        payload = JSON.parse(action.presence || "null")
        payload if payload.is_a?(Hash) && payload["action"] == "approval_gate"
      rescue JSON::ParserError
        nil
      end

      private

      def approval_gate_moved?
        (saved_change_to_creative_id? || saved_change_to_topic_id?) && approval_gate?
      end

      def abandon_deleted_approval_gate = abandon_approval_gate_task
      def abandon_moved_approval_gate = abandon_approval_gate_task

      def abandon_approval_gate_task
        payload = approval_gate_action
        return if payload["mode"] == "async"

        task = Task.find_by(id: payload["task_id"])
        return unless task&.agent_id == user_id

        cancelled = task.with_lock { cancel_undecided_gate(task, payload["tool_call_id"]) }
        return unless cancelled

        Orchestration::ResourceTracker.for(task.agent).release!(task.id) if task.agent
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end

      # A decided gate is already resuming; only an unanswered one is stranded.
      def cancel_undecided_gate(task, tool_call_id)
        pending = task.pending_tool_call
        return false unless task.pending_approval? && pending&.dig("kind") == "approval_gate"
        return false if pending["tool_call_id"] != tool_call_id || pending["decision"]

        task.update!(status: "cancelled", pending_tool_call: nil)
        true
      end
    end
  end
end
