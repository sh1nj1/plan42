# frozen_string_literal: true

module Collavre
  module SystemEvents
    # The registry of event names orchestration can dispatch.
    module Vocabulary
      UnknownEvent = Class.new(ArgumentError)
      Definition = Data.define(:name, :required_keys, :sources)

      EVENTS = {
        "comment_created" => Definition.new(
          name: "comment_created",
          required_keys: %w[comment creative],
          sources: %w[comment_callback cron a2a drop_trigger trigger_restart]
        )
      }.freeze

      def self.names
        EVENTS.keys
      end

      def self.known?(name)
        EVENTS.key?(name.to_s)
      end

      def self.fetch(name)
        EVENTS.fetch(name.to_s) do
          raise UnknownEvent,
            "Unknown system event #{name.inspect}. Known events: #{names.join(', ')}"
        end
      end

      # Required keys are advisory. The dispatcher warns rather than refusing
      # a malformed payload, preserving the behavior of existing callers.
      def self.missing_keys(name, payload)
        return [] unless known?(name)

        payload ||= {}
        fetch(name).required_keys.reject do |key|
          !payload[key].nil? || !payload[key.to_sym].nil?
        end
      end
    end
  end
end
