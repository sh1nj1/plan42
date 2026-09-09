# frozen_string_literal: true

module Collavre
  module CliProxy
    # Records one gateway's readiness verdict on its own row, so every reader —
    # agent presence, the settings screen — answers from the database instead of
    # reaching out to the proxy on a request path.
    class HealthProbe
      # Short on purpose. `/health/ready` never blocks on a probe (the proxy
      # serves a cached snapshot and refreshes behind the response), so anything
      # slow here is the network, and a sweep must not spend the whole interval
      # waiting on one unreachable host.
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 8

      ROLLUP_STATUSES = %w[ok degraded down].freeze
      ERROR_LIMIT = 255

      def initialize(gateway:, client: nil)
        @gateway = gateway
        @client = client || Client.new(
          gateway: gateway, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
        )
      end

      def call
        body = @client.health_ready
        record(rollup(body), engines: engines_of(body), error: nil)
      rescue Client::Error => e
        # A proxy older than the readiness split has no such route. Falling
        # straight to unreachable would report every agent on an entirely
        # healthy older gateway as offline, so ask the liveness endpoint that
        # has always existed and record what it can actually prove.
        return record_liveness_only if e.status == 404

        # Otherwise no verdict was obtained, whatever the cause — DNS, a refused
        # connection, a reverse proxy's error page, a body that is not JSON.
        record(:unreachable, engines: {}, error: e.message)
      end

      private

      def rollup(body)
        status = body.is_a?(Hash) ? body["status"].to_s : ""
        # An answer this Collavre has no name for is still an answer, but it is
        # not evidence the gateway can serve, so it must not read as ok.
        ROLLUP_STATUSES.include?(status) ? status.to_sym : :unknown
      end

      def engines_of(body)
        engines = body.is_a?(Hash) ? body["engines"] : nil
        engines.is_a?(Hash) ? engines : {}
      end

      def record_liveness_only
        @client.health_live
        record(
          :degraded,
          engines: {},
          error: "readiness endpoint unavailable; liveness only (proxy predates /health/ready)"
        )
      rescue Client::Error => e
        record(:unreachable, engines: {}, error: e.message)
      end

      # update_columns, not update!: a health verdict is a denormalized cache of
      # something that lives on the proxy. Saving it normally would run the
      # gateway's workspace-reconciliation callbacks and bump updated_at on a
      # row nobody edited, once a minute, forever.
      def record(status, engines:, error:)
        @gateway.update_columns(
          health_status: AgentGateway.health_statuses.fetch(status.to_s),
          health_engines: engines,
          health_error: error&.to_s&.truncate(ERROR_LIMIT),
          health_checked_at: Time.current
        )
        status
      end
    end
  end
end
