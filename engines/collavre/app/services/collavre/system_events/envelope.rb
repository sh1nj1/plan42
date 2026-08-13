# frozen_string_literal: true

module Collavre
  module SystemEvents
    # JSON-safe metadata that identifies an orchestration dispatch and its
    # causal chain. It travels inside tasks.trigger_event_payload under KEY.
    class Envelope < Data.define(
      :id, :name, :correlation_id, :causation_id, :depth, :source, :occurred_at
    )
      KEY = "event"
      UNKNOWN_SOURCE = "unknown"

      def self.root(name, source: nil)
        id = SecureRandom.uuid
        new(
          id: id,
          name: name.to_s,
          correlation_id: id,
          causation_id: nil,
          depth: 0,
          source: (source.presence || UNKNOWN_SOURCE).to_s,
          occurred_at: Time.current.utc.iso8601
        )
      end

      def self.child(name, parent:, source: nil)
        parent = from(parent) unless parent.is_a?(Envelope)
        return root(name, source: source) if parent.nil?

        root(name, source: source).with(
          correlation_id: parent.correlation_id,
          causation_id: parent.id,
          depth: parent.depth.to_i + 1
        )
      end

      def self.from(hash)
        return hash if hash.is_a?(Envelope)
        return nil unless hash.respond_to?(:to_h)

        hash = hash.to_h.deep_stringify_keys
        id = hash["id"]
        return nil if id.blank?

        new(
          id: id,
          name: hash["name"].to_s,
          correlation_id: hash["correlation_id"].presence || id,
          causation_id: hash["causation_id"].presence,
          depth: hash["depth"].to_i,
          source: hash["source"].presence || UNKNOWN_SOURCE,
          occurred_at: hash["occurred_at"].presence
        )
      rescue TypeError
        nil
      end

      def self.in(context)
        return nil unless context.is_a?(Hash)

        from(context[KEY] || context[KEY.to_sym])
      end

      def root?
        causation_id.nil?
      end

      def to_h
        super.deep_stringify_keys
      end
    end
  end
end
