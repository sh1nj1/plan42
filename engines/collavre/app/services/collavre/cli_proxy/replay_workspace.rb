# frozen_string_literal: true

module Collavre
  module CliProxy
    # Authentication authorizes one workspace, never a replacement created by
    # AiClient after a gateway edit. Validate every inherited login claim using
    # fresh rows; this check must not resolve/create workspaces or use SQL cache.
    module ReplayWorkspace
      def self.permitted?(payload, agent)
        ids = ReplayClaims.ids(payload).map(&:to_i).uniq
        return true if ids.empty?

        Task.uncached do
          current_agent = User.find_by(id: agent.id)
          next false unless current_agent&.cli_proxy_agent? && current_agent.agent_gateway.active?

          claims = Task.where(id: ids, agent_id: agent.id, creative_id: payload.dig("creative", "id"),
                              topic_id: payload.dig("topic", "id")).to_a
          next false unless claims.size == ids.size

          workspace_ids = claims.map { |claim| claim.trigger_event_payload&.dig("engine_login", "workspace_id") }
          next false unless workspace_ids.uniq.size == 1

          workspace = AgentWorkspace.find_by(id: workspace_ids.first, agent_id: agent.id,
                                             agent_gateway_id: current_agent.agent_gateway_id)
          current?(workspace, current_agent, payload)
        end
      end

      def self.current?(workspace, agent, payload)
        return false unless workspace

        user = principal(payload, agent) if agent.agent_gateway.per_user?
        return false if agent.agent_gateway.per_user? && !user

        workspace.user_id == user&.id &&
          workspace.proxy_workspace_id == AgentWorkspace.proxy_workspace_id_for(agent) &&
          workspace.proxy_credential_id == AgentWorkspace.proxy_credential_id_for(agent, user)
      end

      def self.principal(payload, agent)
        if payload.key?("workspace_user_id")
          user = User.find_by(id: payload["workspace_user_id"])
          user unless user&.ai_user?
        else
          user = Comment.find_by(id: payload.dig("comment", "id"))&.user
          user && !user.ai_user? ? user : agent.creator
        end
      end
      private_class_method :current?, :principal
    end
  end
end
