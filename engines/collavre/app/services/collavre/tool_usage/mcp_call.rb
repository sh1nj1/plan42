# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Records a tool call an external client made through /mcp. In-process agents
    # run the RubyLLM tool classes and never reach FastMcp tools, so these calls
    # are not also counted by the agent's internal tool hook.
    #
    # A call made with a cli-openai-proxy workspace callback token is left to the
    # proxy's x_cli_events (source "cli_proxy"): that row carries the agent and
    # the LLM execution, and it also counts calls that never reached /mcp.
    module McpCall
      # The block returns FastMcp's [result, metadata] pair.
      def self.track(tool_name, &block)
        return yield if Current.mcp_agent_workspace_request

        track_call(tool_name, &block)
      end

      def self.track_call(tool_name)
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
      private_class_method :track_call, :record
    end
  end
end
