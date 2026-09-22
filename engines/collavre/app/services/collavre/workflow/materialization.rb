# frozen_string_literal: true

module Collavre
  module Workflow
    class Materialization
      def initialize(row, token:)
        @row = row
        @token = token
      end

      def call
        return unless @row.owned(@token).where(state: "delivering").exists?
        return if @row.task
        execution = @row.execution
        error = Safety.new(execution).reason
        error ||= "task_failed" unless execution.open?
        return stop(error) if error
        result = AiAgentJob.perform_now(@row.agent_id, @row.context["event_name"], @row.context)
        return if @row.task
        error = rejection_reason(execution, result)
        error ? stop(error) : raise(ActiveJob::EnqueueError)
      end

      private

      def rejection_reason(execution, result)
        error = Safety.new(execution).reason
        error ||= "permission_revoked" unless Safety.new(execution).permitted?(User.find_by(id: @row.agent_id))
        error ||= "scheduler_rejected" if result == :rejected
        error ||= "scope_changed" if result == :scope_changed
        error
      end

      def stop(reason)
        changed = @row.owned(@token).where(state: "delivering").update_all(
          state: "failed", reason: reason, claim_token: nil, claimed_at: nil)
        Settlement.new(@row.execution).stop!(reason) if changed == 1
      end
    end
  end
end
