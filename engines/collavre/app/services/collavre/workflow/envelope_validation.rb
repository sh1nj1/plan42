# frozen_string_literal: true

module Collavre
  module Workflow
    module EnvelopeValidation
      def self.reason(context)
        event = context["event"]
        return "invalid_envelope" unless event.is_a?(Hash) && event["id"].present? && event["correlation_id"].present?
        return "invalid_envelope" unless event["depth"].is_a?(Integer) && event["depth"] >= 0
        return "invalid_envelope" unless event["name"] == context["event_name"] && event["occurred_at"].present?
        return "invalid_envelope" unless SystemEvents::Vocabulary.known?(event["name"])
        definition = SystemEvents::Vocabulary.fetch(event["name"])
        return "invalid_envelope" unless definition.sources.include?(event["source"])
        "invalid_envelope" unless definition.required_keys.all? { |key| context[key].is_a?(Hash) }
      end
    end
  end
end
