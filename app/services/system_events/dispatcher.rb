module SystemEvents
  class Dispatcher
    def self.dispatch(event_name, context)
      new.dispatch(event_name, context)
    end

    def dispatch(event_name, context)
      agents = Router.new.route(event_name, context)

      agents.each do |agent|
        AiAgentJob.perform_later(agent.id, event_name, context)
      end
    end
  end
end
