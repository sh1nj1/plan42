# frozen_string_literal: true

module Collavre
  # Vendor-neutral seam for aborting an in-flight agent session when a task is
  # cancelled. Vendor engines register a handler keyed by llm_vendor; core never
  # names a specific backend.
  class AgentSessionAbort
    class << self
      def register(vendor, handler)
        registry[vendor.to_s.downcase] = handler
      end

      def call(agent:, task:, creative: nil, comment: nil)
        handler = registry[agent&.llm_vendor&.downcase]
        return unless handler

        handler.call(agent: agent, task: task, creative: creative, comment: comment)
      rescue StandardError => e
        # A failed abort must never break task cancellation.
        Rails.logger.warn("[AgentSessionAbort] abort failed: #{e.message}")
      end

      def registry
        @registry ||= {}
      end
    end
  end
end
