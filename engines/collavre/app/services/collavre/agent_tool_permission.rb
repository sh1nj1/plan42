# frozen_string_literal: true

module Collavre
  # The persisted tool selection is an execution allowlist, independent of
  # provider schemas, human approval, and creative-level permissions.
  class AgentToolPermission
    def self.current_agent
      Current.mcp_agent_workspace&.agent || Current.agent_turn&.dig(:task)&.agent ||
        (Current.user if Current.user&.ai_user?)
    end

    def self.allowed?(name, agent: current_agent)
      return true unless agent&.ai_user?

      # Read every time: a queued call or approval may outlive a grant. Avoid
      # both an already-loaded agent's attributes and the request query cache.
      selected = agent.class.uncached { agent.class.where(id: agent.id).pick(:tools) }
      Array(selected).include?(name)
    end

    def self.authorize_call!(name, arguments = nil, agent: current_agent)
      loop do
        unless allowed?(name, agent: agent)
          raise Tools::PermissionDeniedError, I18n.t("collavre.mcp_tools.agent_tool_denied", tool_name: name)
        end
        return unless name == "meta_tool" && arguments.is_a?(Hash)

        args = arguments.stringify_keys
        return unless %w[run call].include?(args["action"])

        name, arguments = args["tool_name"], args["arguments"]
      end
    end
  end
end
