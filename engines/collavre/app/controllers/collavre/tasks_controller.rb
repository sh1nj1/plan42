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

      was_delegated = task.status == "delegated"
      task.update!(status: "cancelled")

      # Delegated tasks have no active worker to run the ensure-block release,
      # so free the agent slot and drain the topic queue here.
      if was_delegated && task.agent
        Collavre::Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end

      abort_openclaw_session(task)

      head :ok
    end

    private

    def abort_openclaw_session(task)
      Collavre::OpenclawAbortService.call(agent: task.agent, task: task)
    end
  end
end
