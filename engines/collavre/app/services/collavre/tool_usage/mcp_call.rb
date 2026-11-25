# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Records a tool call an external client made through /mcp. In-process agents
    # run the RubyLLM tool classes and never reach FastMcp tools, so these calls
    # are not also counted by the agent's internal tool hook.
    #
    # A call made with a cli-openai-proxy workspace callback token is tagged with
    # its workspace and a digest of its arguments. When the proxy's matching
    # x_cli_events result arrives, the
    # cli_proxy row (which carries the agent and the LLM execution) replaces it;
    # if the stream breaks first, this row still counts the call.
    # See CliProxyRecorder.
    module McpCall
      SOURCE = "mcp"

      # The block returns FastMcp's [result, metadata] pair.
      def self.track(tool_name, arguments = nil)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        succeeded = false
        pair = yield
        succeeded = !ToolUsage.failed_result?(pair.first)
        pair
      ensure
        record(tool_name, arguments, succeeded, ToolUsage.elapsed_ms(started_at))
      end

      # McpOauthMiddleware sets Current.user to the token owner. An agent token
      # attributes the call to that agent; a human token to that person. A
      # workspace callback token belongs to the workspace user (or the agent, for
      # a shared workspace), but the call is the workspace agent's, so the agent
      # and its owner are taken from the workspace and the token owner stays the
      # requester.
      def self.record(tool_name, arguments, succeeded, duration_ms)
        workspace = Current.mcp_agent_workspace
        Recorder.new(context: context(Current.user, workspace), source: SOURCE, agent_workspace: workspace).record(
          tool_name: tool_name, succeeded: succeeded, duration_ms: duration_ms,
          arguments_digest: workspace && ToolUsage.arguments_digest(arguments)
        )
      rescue StandardError => e
        Rails.logger.error("Failed to persist MCP tool usage: #{e.class}: #{e.message}")
      end

      def self.context(user, workspace)
        return { agent: workspace.agent, requester: user } if workspace
        user&.ai_user? ? { user: user } : { requester: user }
      end
      private_class_method :record, :context
    end
  end
end
