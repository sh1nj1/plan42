# frozen_string_literal: true

module Collavre
  # Fans the periodic readiness probe out, one job per gateway, so a single
  # unreachable host cannot spend the sweep interval and leave the gateways
  # behind it in the loop unprobed.
  class GatewayHealthSweepJob < ApplicationJob
    queue_as :gateway_health
    limits_concurrency to: 1,
      key: -> { "sweep" },
      duration: 5.minutes,
      on_conflict: :discard

    def perform
      AgentGateway.active.pluck(:id).each do |gateway_id|
        GatewayHealthProbeJob.perform_later(gateway_id)
      end
    end
  end
end
