# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Turns the x_cli_events of one cli-openai-proxy run into tool_usages rows.
    #
    # - Only a "result" event is recorded: it carries the outcome. A call that
    #   never gets a result (the run was cut off) records nothing.
    # - The event id is the call_id, so a result reported twice records once.
    # - duration_ms is the gap between the call and result events arriving here.
    #   Streaming delivers them as the CLI runs the tool; a non-streaming
    #   response delivers them together, so it passes timed: false and the
    #   duration stays nil.
    # - Collavre MCP tools the CLI calls are recorded here too, whatever alias the
    #   workspace registered the server under. /mcp has already recorded the call
    #   tagged with the workspace and a digest of its arguments, so a recorded
    #   result replaces the /mcp row of this run with the same tool and
    #   arguments, and each call is counted once. Another run sharing the
    #   workspace can't take that row unless it made the identical call. A call
    #   whose result never arrives keeps its /mcp row; a call that never reached
    #   /mcp replaces nothing. Only when the proxy clipped the input (over 4KB)
    #   does the result fall back to the oldest row of that tool. See McpCall.
    class CliProxyRecorder
      SOURCE = "cli_proxy"
      # "mcp__<alias>__<tool>" (Claude) and "<alias>.<tool>" (Codex)
      MCP_TOOL_NAME = /\A(?:mcp__.+__|[^.]+\.)(?<tool>[^.]+)\z/

      def initialize(context:, execution_id:, agent_workspace: nil, since: nil)
        @recorder = Recorder.new(context: context, source: SOURCE, execution_id: execution_id)
        @agent_workspace_id = agent_workspace&.id
        @since = since
        @started = {}
        @inputs = {}
        @recorded = Set.new
      end

      def execution_id
        @recorder.execution_id
      end

      def observe(event, timed: true)
        event = event.to_h.stringify_keys
        id = event["id"].to_s
        case event["phase"]
        when "call" then observe_call(event, id, timed)
        when "result" then record_result(event, id)
        end
      end

      private

      def observe_call(event, id, timed)
        return if id.blank?

        @inputs[id] = event["input"]
        @started[id] ||= monotonic_now if timed
      end

      def record_result(event, id)
        started = @started.delete(id)
        input = @inputs.delete(id)
        return if id.present? && !@recorded.add?(id)

        name = event["name"].presence || "tool"
        row = @recorder.record(
          tool_name: name, succeeded: succeeded?(event),
          duration_ms: started && ((monotonic_now - started) * 1000).round, call_id: id.presence
        )
        replace_mcp_row(name, input) if row
      end

      def replace_mcp_row(name, input)
        tool = MCP_TOOL_NAME.match(name)&.[](:tool)
        return unless tool && @agent_workspace_id && @since

        rows = ToolUsage.where(source: McpCall::SOURCE, agent_workspace_id: @agent_workspace_id, tool_name: tool)
                        .where(occurred_at: @since..).order(:occurred_at, :id)
        digest = ToolUsage.arguments_digest(input)
        (digest ? rows.find_by(arguments_digest: digest) : rows.first)&.destroy
      end

      def succeeded?(event)
        return event["ok"] == true unless event["ok"].nil?

        event["exitCode"].nil? || event["exitCode"].to_i.zero?
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
