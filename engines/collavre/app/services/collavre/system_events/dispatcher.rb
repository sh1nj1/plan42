module Collavre
  module SystemEvents
    class Dispatcher
      def self.dispatch(event_name, context)
        new.dispatch(event_name, context)
      end
  
      def dispatch(event_name, context)
        # Build context once to ensure consistency between Router and Job
        enriched_context = ContextBuilder.new(context).build
        agents = Router.new.route(event_name, enriched_context)
  
        agents.each do |agent|
          AiAgentJob.perform_later(agent.id, event_name, enriched_context)
        end
      end
    end
  end
end
