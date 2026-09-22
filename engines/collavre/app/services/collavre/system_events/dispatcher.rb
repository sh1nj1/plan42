# frozen_string_literal: true

module Collavre
  module SystemEvents
    # The only entry point to orchestration. It validates the event type and
    # stamps its envelope before the payload is persisted or scheduled.
    class Dispatcher
      def self.dispatch(event_name, context, **options)
        new.dispatch(event_name, context, **options)
      end

      def self.dispatch_with_outcome(event_name, context, **options)
        new.dispatch_with_outcome(event_name, context, **options)
      end

      def dispatch(event_name, context, **options)
        dispatch_with_outcome(event_name, context, **options).agents
      end

      def dispatch_with_outcome(event_name, context, source: nil, parent: nil, invocation: nil, **options)
        definition = Vocabulary.fetch(event_name)
        identity = Workflow::Receipt.identity(invocation, definition.name, source)
        recovered = Workflow::Receipt.recover(identity)
        return recovered if recovered
        ctx = (context || {}).deep_stringify_keys.except("workflow_execution_id")
        envelope = resolve_envelope(definition.name, ctx, source, parent)
        ctx[Envelope::KEY] = dispatch_metadata(ctx, envelope, parent)
        warn_missing_keys(definition, ctx, envelope)
        log_dispatch(definition, ctx, envelope)
        Orchestration::AgentOrchestrator.dispatch_with_outcome(definition.name, ctx, invocation: invocation, **options)
      end

      private

      def dispatch_metadata(context, envelope, parent)
        metadata = envelope.to_h
        original = context[Envelope::KEY]
        if !parent && original.is_a?(Hash) && original["name"] == envelope.name
          metadata["depth"] = original["depth"]
        end
        metadata
      end

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
