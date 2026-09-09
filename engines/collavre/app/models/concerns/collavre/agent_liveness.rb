# frozen_string_literal: true

module Collavre
  # Whether an agent can be dispatched to right now.
  #
  # Deliberately independent of chat presence: presence answers "who has this
  # creative open", which drives read receipts and unread badges, while this
  # answers "can this agent run", which is true whether or not anyone is
  # watching. The two meet only where an avatar paints its online dot.
  module AgentLiveness
    extend ActiveSupport::Concern

    def claude_channel_agent?
      llm_model == "claude-code"
    end

    def claude_channel_online?
      claude_channel_agent? && AgentSubscription.live.where(agent_id: id).exists?
    end

    # A gateway-backed agent is reachable when its gateway's last readiness
    # probe is recent, positive, and does not name this agent's own engine as
    # logged out. See docs/agent_gateway_health.md.
    def gateway_online?
      return false unless cli_proxy_agent?

      agent_gateway.health_serves_engine?(CliProxy::AdapterEngine.for_model(llm_model))
    end

    # Only the two agent kinds that publish evidence either way. An agent on a
    # hosted vendor API publishes none, so it stays out rather than being
    # asserted online on nothing.
    def agent_online?
      claude_channel_online? || gateway_online?
    end
  end
end
