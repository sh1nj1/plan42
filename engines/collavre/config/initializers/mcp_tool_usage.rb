# frozen_string_literal: true

return unless defined?(FastMcp::Tool)

module Collavre
  # FastMcp::Server calls this for every /mcp tools/call; nothing in-process does.
  module McpToolUsageTracking
    def call_with_schema_validation!(**)
      Collavre::ToolUsage::McpCall.track(self.class.tool_name) { super }
    end
  end
end

FastMcp::Tool.prepend(Collavre::McpToolUsageTracking)
