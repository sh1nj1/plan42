module Collavre
  module SystemEvents
    # @deprecated Use Collavre::Orchestration::Matcher instead.
    # This class is kept for backward compatibility and will be removed in a future version.
    class Router
      def route(event_name, context)
        Rails.logger.warn(
          "[DEPRECATED] Collavre::SystemEvents::Router is deprecated. " \
          "Use Collavre::Orchestration::AgentOrchestrator.dispatch instead."
        )

        # Build context with event_name for Matcher
        enriched_context = ContextBuilder.new(context).build
        enriched_context["event_name"] = event_name

        # Delegate to new Matcher
        Orchestration::Matcher.new(enriched_context).match
      end
    end
  end
end
