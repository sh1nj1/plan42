# frozen_string_literal: true

module Collavre
  module AgentHealth
    # Executes one optional vendor checker and stores its observational result.
    class Probe
      VALID_STATUSES = %i[online offline unknown].freeze
      ERROR_LIMIT = 255

      def initialize(agent:)
        @agent = agent
        @configuration_updated_at = agent.updated_at
      end

      def call
        checker = AgentHealth.checker_for(@agent.llm_vendor)
        return :unsupported unless checker

        result = checker.new(agent: @agent).call
        raise ArgumentError, "health checker returned an invalid result" unless valid_result?(result)

        record(result.status.to_sym, result.error)
      rescue StandardError => e
        Rails.logger.error(
          "[AgentHealth::Probe] agent=#{@agent.id} vendor=#{@agent.llm_vendor} checker_error=#{e.class}"
        )
        record(:check_error, e.class.name)
      end

      private

      def valid_result?(result)
        result.is_a?(Result) && VALID_STATUSES.include?(result.status.to_sym)
      end

      def record(status, error)
        User.where(id: @agent.id, updated_at: @configuration_updated_at).update_all(
          endpoint_health_status: User.endpoint_health_statuses.fetch(status.to_s),
          endpoint_health_error: error&.to_s&.truncate(ERROR_LIMIT),
          endpoint_health_checked_at: Time.current
        )
        status
      end
    end
  end
end
