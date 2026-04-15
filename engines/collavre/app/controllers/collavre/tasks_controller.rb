# frozen_string_literal: true

module Collavre
  class TasksController < ApplicationController
    def cancel
      task = Task.find(params[:id])
      creative = task.creative || Creative.find_by(id: task.trigger_event_payload&.dig("creative", "id"))

      unless creative && creative.has_permission?(Current.user, :feedback)
        return head :forbidden
      end

      unless %w[running pending queued pending_approval].include?(task.status)
        return head :unprocessable_entity
      end

      task.update!(status: "cancelled")

      abort_openclaw_session(task)

      head :ok
    end

    private

    def abort_openclaw_session(task)
      Collavre::OpenclawAbortService.call(agent: task.agent, task: task)
    end
  end
end
