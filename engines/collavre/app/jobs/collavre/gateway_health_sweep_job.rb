# frozen_string_literal: true

module Collavre
  # Fans the periodic readiness probe out, one job per gateway, so a single
  # unreachable host cannot spend the sweep interval and leave the gateways
  # behind it in the loop unprobed.
  class GatewayHealthSweepJob < ApplicationJob
    CONCURRENCY_DURATION = 1.day
    queue_as :gateway_health
    # Keep a delayed sweep coalesced for the same overload window as its probes.
    limits_concurrency to: 1,
      key: -> { "sweep" },
      duration: CONCURRENCY_DURATION,
      on_conflict: :discard

    def perform
      AgentGateway.active.pluck(:id).each do |gateway_id|
        GatewayHealthProbeJob.perform_later(gateway_id)
      end
    end
  end
end
