# frozen_string_literal: true

module Collavre
  class EndpointHealthSweepJob < ApplicationJob
    CONCURRENCY_DURATION = 1.day
    queue_as :gateway_health

    limits_concurrency to: 1,
      key: -> { "endpoint-health-sweep" },
      duration: CONCURRENCY_DURATION,
      on_conflict: :discard

    def perform
      vendors = AgentHealth.vendors
      return if vendors.empty?

      User.ai_agents.where("LOWER(TRIM(llm_vendor)) IN (?)", vendors).pluck(:id).each do |agent_id|
        EndpointHealthProbeJob.perform_later(agent_id)
      end
    end
  end
end
