# frozen_string_literal: true

module Collavre
  class GatewayHealthProbeJob < ApplicationJob
    # Isolated from the default pool: a probe blocks on an unreachable host for
    # seconds at a time, and there is one per gateway every minute.
    queue_as :gateway_health

    # The sweep enqueues unconditionally, so a queue that fell behind holds
    # copies of probes whose verdict has since been recorded. Re-probing on
    # those is what turns a slow sweep into a backlog that compounds; half the
    # sweep interval is late enough to be redundant and early enough that no
    # gateway drifts toward HEALTH_TTL waiting for its turn.
    DEBOUNCE = 30.seconds

    def perform(gateway_id)
      gateway = AgentGateway.active.find_by(id: gateway_id)
      return unless gateway
      return if gateway.health_checked_at.present? && gateway.health_checked_at > DEBOUNCE.ago

      CliProxy::HealthProbe.new(gateway: gateway).call
    rescue StandardError => e
      # The probe already turns every transport failure into a recorded verdict,
      # so anything arriving here is a bug in this code path. Retrying it would
      # re-raise on the next sweep too; the stale verdict expires on its own.
      Rails.logger.error("[GatewayHealthProbeJob] gateway=#{gateway_id} #{e.class}: #{e.message}")
    end
  end
end
