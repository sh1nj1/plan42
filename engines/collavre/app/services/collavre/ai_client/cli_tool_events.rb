# frozen_string_literal: true

module Collavre
  class AiClient
    # Tool activity of a cli_proxy run. The CLI behind cli-openai-proxy runs its
    # own tools (Bash, file edits, MCP calls, subagents), so they never pass
    # through RubyLLM's tool loop. The proxy reports them as x_cli_events only
    # when asked, and only cli_proxy is asked: real OpenAI and other gateways
    # never see the extension key.
    #
    # Each event is handed to the #on_cli_tool_event listeners (for live
    # progress UIs) and recorded as a ToolUsage under the same execution_id as
    # the run's LlmUsage rows.
    module CliToolEvents
      REQUEST_PARAMS = { x_cli_events: "reasoning" }.freeze

      # Registers a listener called with each raw event Hash
      # ({ "id", "phase", "name", "input", "output", "exitCode", "ok", "parentId" })
      # as it streams in. A failing listener is logged and never breaks the chat.
      def on_cli_tool_event(&block)
        cli_tool_event_listeners << block if block
        self
      end

      private

      def cli_tool_event_listeners
        @cli_tool_event_listeners ||= []
      end

      def install_cli_tool_events(chat)
        return unless vendor == "cli_proxy"

        # with_params replaces rather than merges, so the run's reasoning effort
        # rides on this one call.
        effort = cli_reasoning_effort
        chat.with_params(**REQUEST_PARAMS, **(effort ? { reasoning_effort: effort } : {}))
        # Non-streaming responses (#ask) carry their events on the final message.
        # A streamed message is rebuilt by RubyLLM without them, so the events
        # seen per chunk are never dispatched twice.
        chat.after_message { |message| dispatch_cli_tool_events(message, timed: false) }
      end

      def cli_reasoning_effort
        candidates = [ context&.dig(:reasoning_effort), context&.dig(:user)&.reasoning_effort ]
        allowed = CliProxy::RunOptions.efforts_for(model)
        candidates.map { |value| value.to_s.strip }.find { |value| allowed.include?(value) }
      end

      def observe_chunk(chunk)
        observe_usage(chunk)
        dispatch_cli_tool_events(chunk, timed: true)
      end

      def dispatch_cli_tool_events(message, timed:)
        return unless vendor == "cli_proxy" && message.respond_to?(:cli_events)

        # Record before notifying: a listener may cancel the run, and the tool
        # behind the event has already run either way.
        message.cli_events.each do |event|
          record_cli_tool_event(event, timed)
          cli_tool_event_listeners.each { |listener| notify_cli_tool_event(listener, event) }
        end
      end

      def notify_cli_tool_event(listener, event)
        listener.call(event)
      rescue CancelledError
        raise
      rescue StandardError => e
        Rails.logger.error("CLI tool event listener failed: #{e.class}: #{e.message}")
      end

      def record_cli_tool_event(event, timed)
        cli_tool_usage&.observe(event, timed: timed)
      rescue StandardError => e
        Rails.logger.error("Failed to record CLI tool usage: #{e.class}: #{e.message}")
      end

      # Follows the current LlmUsage recorder, so #chat and a later #ask each
      # record under their own execution. No usage recorder (log_interactions:
      # false) means no tool usage either, matching LlmUsage.
      def cli_tool_usage
        return unless @usage_recorder

        execution_id = @usage_recorder.execution_id
        @cli_tool_usage = nil unless @cli_tool_usage&.execution_id == execution_id
        @cli_tool_usage ||= ToolUsage::CliProxyRecorder.new(
          context: context, execution_id: execution_id,
          agent_workspace: @cli_proxy_identity&.dig(:workspace), since: @usage_started_at
        )
      end
    end
  end
end
