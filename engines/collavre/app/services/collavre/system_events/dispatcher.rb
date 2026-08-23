# frozen_string_literal: true

module Collavre
  module SystemEvents
    # The only entry point to orchestration. It validates the event type and
    # stamps its envelope before the payload is persisted or scheduled.
    class Dispatcher
      def self.dispatch(event_name, context, source: nil, parent: nil, selected_agents: nil, context_for: nil)
        new.dispatch(
          event_name, context, source: source, parent: parent,
          selected_agents: selected_agents, context_for: context_for
        )
      end

      def dispatch(event_name, context, source: nil, parent: nil, selected_agents: nil, context_for: nil)
        definition = Vocabulary.fetch(event_name)
        ctx = (context || {}).deep_stringify_keys
        envelope = resolve_envelope(definition.name, ctx, source, parent)
        ctx[Envelope::KEY] = envelope.to_h

        warn_missing_keys(definition, ctx, envelope)
        log_dispatch(definition, ctx, envelope)

        Orchestration::AgentOrchestrator.dispatch(
          definition.name, ctx, selected_agents: selected_agents, context_for: context_for
        )
      end

      private

      def resolve_envelope(event_name, context, source, parent)
        return Envelope.child(event_name, parent: parent, source: source) if parent

        existing = Envelope.in(context)
        return Envelope.root(event_name, source: source) if existing.nil?
        return existing if existing.name == event_name

        Envelope.child(event_name, parent: existing, source: source)
      end

      def warn_missing_keys(definition, context, envelope)
        missing = Vocabulary.missing_keys(definition.name, context)
        return if missing.empty?

        Rails.logger.warn(
          "[SystemEvents::Dispatcher] event=#{definition.name} " \
          "event_id=#{envelope.id} missing_keys=#{missing.join(',')}"
        )
      end

      def log_dispatch(definition, context, envelope)
        Rails.logger.info(
          "[SystemEvents::Dispatcher] event=#{definition.name} " \
          "event_id=#{envelope.id} correlation_id=#{envelope.correlation_id} " \
          "causation_id=#{envelope.causation_id || '-'} depth=#{envelope.depth} " \
          "source=#{envelope.source} " \
          "comment_id=#{context.dig('comment', 'id')} " \
          "comment_user_id=#{context.dig('comment', 'user_id')} " \
          "creative_id=#{context.dig('creative', 'id')} " \
          "caller=#{caller_locations(1, 5)&.map { |location| "#{File.basename(location.path)}:#{location.lineno}" }&.join(' <- ')}"
        )
      end
    end
  end
end
