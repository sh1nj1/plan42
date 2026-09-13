# frozen_string_literal: true

module Collavre
  module Workflow
    class Materialization
      def initialize(row)
        @row = row
      end

      def call
        return if @row.task
        execution = @row.execution
        error = Safety.new(execution).reason
        error ||= "task_failed" unless execution.open?
        return stop(error) if error
        result = AiAgentJob.perform_now(@row.agent_id, @row.context["event_name"], @row.context)
        return if @row.task
        error = Safety.new(execution).reason
        error ||= "permission_revoked" unless Safety.new(execution).permitted?(User.find_by(id: @row.agent_id))
        error ||= "scheduler_rejected" if result == :rejected
        error ||= "scope_changed" if result == :scope_changed
        error ? stop(error) : raise(ActiveJob::EnqueueError)
      end

      private

      def stop(reason)
        @row.finish!(reason)
        Settlement.new(@row.execution).stop!(reason)
      end
    end
  end
end
