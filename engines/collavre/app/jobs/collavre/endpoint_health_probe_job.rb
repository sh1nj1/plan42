# frozen_string_literal: true

module Collavre
  class EndpointHealthProbeJob < ApplicationJob
    CONCURRENCY_DURATION = 1.day
    queue_as :gateway_health

    limits_concurrency to: 1,
      key: ->(agent_id) { agent_id },
      duration: CONCURRENCY_DURATION,
      on_conflict: :discard

    def perform(agent_id)
      agent = User.ai_agents.find_by(id: agent_id)
      return unless agent && AgentHealth.checker_for(agent.llm_vendor)

      AgentHealth::Probe.new(agent: agent).call
    rescue StandardError => e
      Rails.logger.error("[EndpointHealthProbeJob] agent=#{agent_id} orchestration_error=#{e.class}")
    end
  end
end
