# frozen_string_literal: true

module Collavre
  # Whether a tool call must wait for human approval: a dynamic McpTool or a
  # system tool may require it globally, and an agent may require it for its
  # own calls via agent_conf `approval: { tools: [...] }` — so one agent can
  # gate its write tools without changing them for every other agent.
  class ToolApprovalPolicy
    def self.required?(tool_name, agent: nil)
      McpTool.find_by(name: tool_name)&.requires_approval? ||
        system_tool_requires_approval?(tool_name) ||
        agent_requires_approval?(agent, tool_name)
    end

    def self.agent_requires_approval?(agent, tool_name)
      return false unless agent

      Array(agent.parsed_agent_conf.dig("approval", "tools")).map(&:to_s).include?(tool_name.to_s)
    end

    def self.system_tool_requires_approval?(tool_name)
      klass = ToolMeta.registry.find { |service| service.tool_metadata[:name] == tool_name }
      klass.respond_to?(:requires_approval?) && klass.requires_approval?
    end
    private_class_method :system_tool_requires_approval?
  end
end
