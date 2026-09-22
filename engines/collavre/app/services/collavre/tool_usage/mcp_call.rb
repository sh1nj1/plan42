# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Records a tool call an external client made through /mcp. In-process agents
    # run the RubyLLM tool classes and never reach FastMcp tools, so these calls
    # are not also counted by the agent's internal tool hook.
    module McpCall
      # The block returns FastMcp's [result, metadata] pair.
      def self.track(tool_name)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        succeeded = false
        pair = yield
        succeeded = !ToolUsage.failed_result?(pair.first)
        pair
      ensure
        record(tool_name, succeeded, ToolUsage.elapsed_ms(started_at))
      end

      # McpOauthMiddleware sets Current.user to the token owner. An agent token
      # attributes the call to that agent; a human token to that person.
      def self.record(tool_name, succeeded, duration_ms)
        user = Current.user
        context = user&.ai_user? ? { user: user } : { requester: user }
        Recorder.new(context: context, source: "mcp").record(tool_name: tool_name, succeeded: succeeded, duration_ms: duration_ms)
      rescue StandardError => e
        Rails.logger.error("Failed to persist MCP tool usage: #{e.class}: #{e.message}")
      end
      private_class_method :record
    end
  end
end
