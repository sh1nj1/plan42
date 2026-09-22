# frozen_string_literal: true

module Collavre
  class ApprovalGateResumeJob < ApplicationJob
    self.enqueue_after_transaction_commit = true

    queue_as :ai_agents

    def perform(task_id, tool_call_id)
      task = Task.find_by(id: task_id)
      return unless task

      pending = task.pending_tool_call
      return unless task.pending_approval? && pending&.dig("kind") == "approval_gate"
      return unless pending["tool_call_id"] == tool_call_id && pending["decision"]

      # TaskAdmission atomically promotes pending_approval to running. A retry
      # before that transition remains runnable; duplicates after it cannot start.
      AiAgentJob.perform_now(task)
    end
  end
end
