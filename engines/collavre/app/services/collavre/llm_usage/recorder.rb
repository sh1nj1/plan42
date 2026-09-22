# frozen_string_literal: true

module Collavre
  class LlmUsage
    class Recorder
      attr_reader :execution_id

      def initialize(context:, vendor:, model:, measurement: nil)
        @identity = Attribution.snapshot(context).merge(agent_id: Attribution.agent(context)&.id, vendor: vendor, model: model.to_s)
        @execution_id = SecureRandom.uuid
        @measurement = measurement || (vendor == "cli_proxy" ? "run" : "call")
        @sequence = 0
        @seen = {}.compare_by_identity
        @pending_parts = {}
        @pending = false
      end

      def observe(chunk)
        @pending = true
        @pending_parts.merge!(TokenNormalizer.parts(chunk).compact)
      end

      def record(response)
        return if response.respond_to?(:role) && response.role != :assistant
        return if @seen.key?(response)

        @seen[response] = true
        persist(TokenNormalizer.parts(response), TokenNormalizer.raw_usage(response))
        @pending_parts = {}
        @pending = false
      end

      def finish(response = nil)
        record(response) if response
        persist(@pending_parts, {}) if @pending || @sequence.zero?
        @pending_parts = {}
        @pending = false
      end

      def attach(log)
        return unless log.is_a?(ActivityLog)

        LlmUsage.where(execution_id: execution_id).update_all(activity_log_id: log.id)
      end

      private

      def persist(parts, raw)
        @sequence += 1
        LlmUsage.create!(
          @identity.merge(TokenNormalizer.normalize(parts, raw, vendor: @identity[:vendor])).merge(
            event_key: "#{execution_id}:#{@sequence}", execution_id: execution_id,
            measurement: @measurement, occurred_at: Time.current
          )
        )
      end
    end
  end
end
