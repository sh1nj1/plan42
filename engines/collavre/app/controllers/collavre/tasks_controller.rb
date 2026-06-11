# frozen_string_literal: true

module Collavre
  class TasksController < ApplicationController
    def cancel
      task = Task.find(params[:id])
      creative = task.creative || Creative.find_by(id: task.trigger_event_payload&.dig("creative", "id"))

      unless creative && creative.has_permission?(Current.user, :feedback)
        return head :forbidden
      end

      unless %w[running pending queued pending_approval delegated].include?(task.status)
        return head :unprocessable_entity
      end

      # delegated and pending_approval tasks have already returned from
      # AiAgentJob while deliberately holding the slot (should_release = false):
      # delegated awaits an external MCP reply, pending_approval paused on
      # ApprovalPendingError. No live worker will run the ensure-block release,
      # so free the agent slot and drain the topic queue here — otherwise
      # cancelling the blocker leaves agent capacity and the queued waiter stuck.
      held_slot_without_worker = %w[delegated pending_approval].include?(task.status)
      task.update!(status: "cancelled")

      if held_slot_without_worker && task.agent
        Collavre::Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end

      abort_agent_session(task)

      head :ok
    end

    private

    def abort_agent_session(task)
      Collavre::AgentSessionAbort.call(agent: task.agent, task: task)
    end
  end
end
