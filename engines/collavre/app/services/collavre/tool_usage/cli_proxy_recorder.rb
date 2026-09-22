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
    # - A Collavre MCP tool called by the CLI is skipped: it reaches Collavre's
    #   /mcp endpoint, which records it as source "mcp". See .collavre_mcp_tool?.
    class CliProxyRecorder
      SOURCE = "cli_proxy"

      # Claude Code names an MCP tool "mcp__<server>__<tool>"; Codex reports
      # "<server>.<tool>". The server is whatever the workspace registered
      # Collavre as ("collavre", "plugin_collavre_collavre", ...), so the rule is
      # "the server segment contains collavre". Built-in tools (Bash, Edit,
      # command_execution, ...) have no server segment and never match.
      def self.collavre_mcp_tool?(name)
        name = name.to_s
        server = name[/\Amcp__(.+?)__/, 1] || name[/\A([^.]+)\./, 1]
        server.to_s.downcase.include?("collavre")
      end

      def initialize(context:, execution_id:)
        @recorder = Recorder.new(context: context, source: SOURCE, execution_id: execution_id)
        @started = {}
        @recorded = Set.new
      end

      def execution_id
        @recorder.execution_id
      end

      def observe(event, timed: true)
        event = event.to_h.stringify_keys
        id = event["id"].to_s
        case event["phase"]
        when "call" then @started[id] ||= monotonic_now if timed && id.present?
        when "result" then record_result(event, id)
        end
      end

      private

      def record_result(event, id)
        started = @started.delete(id)
        return if self.class.collavre_mcp_tool?(event["name"])
        return if id.present? && !@recorded.add?(id)

        @recorder.record(
          tool_name: event["name"].presence || "tool", succeeded: succeeded?(event),
          duration_ms: started && ((monotonic_now - started) * 1000).round, call_id: id.presence
        )
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
