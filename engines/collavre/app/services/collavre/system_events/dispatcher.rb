module Collavre
  module SystemEvents
    class Dispatcher
      def self.dispatch(event_name, context)
        new.dispatch(event_name, context)
      end

      def dispatch(event_name, context)
        # Delegate to AgentOrchestrator for unified routing/scheduling
        Orchestration::AgentOrchestrator.dispatch(event_name, context)
      end
    end
  end
end
