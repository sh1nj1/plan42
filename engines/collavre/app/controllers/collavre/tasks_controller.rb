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

      # These statuses count against the topic slot (occupying_topic_slot) yet no
      # live worker will run AiAgentJob's ensure-block drain for them:
      #   - delegated / pending_approval already returned from the job holding the
      #     slot (should_release = false) — awaiting an MCP reply / approval.
      #   - pending may be a waiter that dequeue_next_for_topic promoted
      #     queued -> pending before its job starts; once cancelled, that job
      #     early-returns at the top of #perform and never reaches the ensure drain.
      # So free the agent slot and drain the topic queue here — otherwise
      # cancelling the blocker leaves agent capacity and the next waiter stuck
      # until stuck recovery. release!/dequeue are idempotent (dequeue is bounded
      # by topic_at_capacity?), so a racing live worker that also drains is harmless.
      held_slot_without_worker = %w[pending delegated pending_approval].include?(task.status)
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
