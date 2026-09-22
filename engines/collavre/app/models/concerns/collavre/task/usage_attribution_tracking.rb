# frozen_string_literal: true

module Collavre
  class Task
    module UsageAttributionTracking
      extend ActiveSupport::Concern

      included do
        before_create :capture_usage_requesters
        before_update :extend_usage_requesters
      end

      private

      def capture_usage_requesters
        self.usage_attribution = LlmUsage::Attribution.from_payload(trigger_event_payload || {})
      end

      def extend_usage_requesters
        return unless will_save_change_to_trigger_event_payload?
        return unless status_in_database.in?(%w[pending queued])

        additions = LlmUsage::Attribution.from_payload(trigger_event_payload || {})
        self.usage_attribution = LlmUsage::Attribution.merge(usage_attribution, additions)
      end
    end
  end
end
