# frozen_string_literal: true

module Collavre
  class GatewayHealthProbeJob < ApplicationJob
    queue_as :default

    def perform(gateway_id)
      gateway = AgentGateway.active.find_by(id: gateway_id)
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
