# frozen_string_literal: true

module Collavre
  class GatewayHealthProbeJob < ApplicationJob
    CONCURRENCY_DURATION = 1.day
    # Isolated from the default pool: a probe blocks on an unreachable host for
    # seconds at a time, and there is one per assigned gateway every minute.
    queue_as :gateway_health

    # Claim the semaphore when the probe is enqueued, not when it starts. A
    # later sweep therefore discards a duplicate while this gateway already has
    # a ready or running probe instead of growing the queue under overload. The
    # one-day failsafe outlives the queue time for thousands of worst-case
    # probes; normal completion releases it immediately.
    limits_concurrency to: 1,
      key: ->(gateway_id) { gateway_id },
      duration: CONCURRENCY_DURATION,
      on_conflict: :discard

    def perform(gateway_id)
      gateway = AgentGateway.health_probe_targets.find_by(id: gateway_id)
      return unless gateway

      CliProxy::HealthProbe.new(gateway: gateway).call
    rescue StandardError => e
      # The probe already turns every transport failure into a recorded verdict,
      # so anything arriving here is a bug in this code path. Retrying it would
      # re-raise on the next sweep too; the stale verdict expires on its own.
      Rails.logger.error("[GatewayHealthProbeJob] gateway=#{gateway_id} #{e.class}: #{e.message}")
    end
  end
end
