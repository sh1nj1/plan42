# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Approval replay bypasses the agent tool callbacks; account at execution instead.
    class ApprovedInvocation
      def self.call(task, tool_name)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        succeeded = false
        result = yield
        succeeded = !ToolUsage.failed_result?(result)
        result
      ensure
        record(task, tool_name, succeeded, started_at)
      end

      def self.record(task, tool_name, succeeded, started_at)
        Recorder.new(context: { task: task }, source: "internal").record(
          tool_name: tool_name, succeeded: succeeded, duration_ms: ToolUsage.elapsed_ms(started_at),
          call_id: task.pending_tool_call&.dig("tool_call_id")
        )
      rescue StandardError => e
        Rails.logger.error("Failed to persist approved tool usage: #{e.class}: #{e.message}")
      end
      private_class_method :record
    end
  end
end
