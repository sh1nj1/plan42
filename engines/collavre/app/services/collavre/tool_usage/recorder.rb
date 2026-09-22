# frozen_string_literal: true

module Collavre
  class ToolUsage
    # Records tool calls of one execution. Attribution is snapshotted once, the same
    # way LlmUsage::Recorder does, so both tables share execution_id and identity.
    class Recorder
      attr_reader :execution_id

      def initialize(context:, source:, execution_id: nil, agent_workspace: nil)
        @identity = LlmUsage::Attribution.snapshot(context).merge(agent_id: LlmUsage::Attribution.agent(context)&.id)
        @identity[:agent_workspace_id] = agent_workspace.id if agent_workspace
        @source = source
        @execution_id = execution_id || SecureRandom.uuid
        @sequence = 0
      end

      # call_id makes the event idempotent when the same call is reported twice.
      def record(tool_name:, succeeded: true, duration_ms: nil, call_id: nil, occurred_at: Time.current)
        @sequence += 1
        ToolUsage.create!(
          @identity.merge(
            event_key: "#{execution_id}:#{@source}:#{call_id.presence || "seq-#{@sequence}"}",
            execution_id: execution_id, source: @source, tool_name: tool_name.to_s,
            succeeded: succeeded, duration_ms: duration_ms, occurred_at: occurred_at
          )
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
  end
end
