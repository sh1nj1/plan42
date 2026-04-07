# frozen_string_literal: true

module Collavre
  class TasksController < ApplicationController
    def cancel
      task = Task.find(params[:id])
      creative = task.creative || Creative.find_by(id: task.trigger_event_payload&.dig("creative", "id"))

      unless creative && creative.has_permission?(Current.user, :feedback)
        return head :forbidden
      end

      unless %w[running pending queued].include?(task.status)
        return head :unprocessable_entity
      end

      task.update!(status: "cancelled")

      abort_openclaw_session(task)

      head :ok
    end

    private

    def abort_openclaw_session(task)
      return unless task.agent.llm_vendor&.downcase == "openclaw"
      return unless defined?(CollavreOpenclaw::ConnectionManager)

      conn = CollavreOpenclaw::ConnectionManager.instance.connection_for(task.agent)
      session_key = build_session_key(task)
      conn.chat_abort(session_key: session_key)
    rescue StandardError => e
      Rails.logger.warn("[TasksController] OpenClaw abort failed: #{e.message}")
    end

    def build_session_key(task)
      context = task.trigger_event_payload || {}
      CollavreOpenclaw::OpenclawAdapter.new(
        user: task.agent,
        system_prompt: "",
        context: context
      ).session_key
    end
  end
end
