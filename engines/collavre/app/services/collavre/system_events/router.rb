module Collavre
  module SystemEvents
    class Router
      def route(event_name, context)
        # Build the context for Liquid
        liquid_context = Collavre::SystemEvents::ContextBuilder.new(context).build
        liquid_context["event_name"] = event_name

        # Priority 1: Mention-based routing (exclusive)
        # If any user is mentioned, mention routing takes over exclusively.
        # - Mentioned AI agent → route only to that agent
        # - Mentioned non-AI user → route to nobody (no AI agents)
        mentioned_result = find_mentioned_routing(liquid_context, context)
        return mentioned_result unless mentioned_result.nil?

        # Priority 2: Liquid expression routing (fallback, only when no mention)
        route_by_liquid_expression(liquid_context, context)
      end

      private

      # Returns Array of agents to route to, or nil if no mention was found.
      # When a mention IS found, this is exclusive:
      #   - AI agent mentioned → [agent] (if permitted)
      #   - Non-AI user mentioned → [] (no AI agents should receive it)
      def find_mentioned_routing(liquid_context, context)
        mentioned_user_data = liquid_context.dig("chat", "mentioned_user")
        return nil unless mentioned_user_data && mentioned_user_data["id"]

        mentioned_user = User.find_by(id: mentioned_user_data["id"])
        return nil unless mentioned_user

        # Mention found — this is exclusive routing.
        # If the mentioned user is not an AI agent, no AI agents should receive the message.
        return [] unless mentioned_user.ai_user?

        # Permission check for mentioned AI agent
        return [] unless has_creative_permission?(mentioned_user, context)

        [ mentioned_user ]
      end

      def route_by_liquid_expression(liquid_context, context)
        # Find all AI agents
        agents = User.where.not(llm_vendor: nil)

        matched_agents = []

        agents.each do |agent|
          next if agent.routing_expression.blank?

          # Permission Check
          next unless has_creative_permission?(agent, context)

          begin
            # Add 'agent' to context so they can refer to themselves
            agent_context = liquid_context.merge("agent" => agent.as_json(only: [ :id, :name, :email ]))

            # Parse and evaluate the routing expression
            # We wrap the expression in an if block to evaluate truthiness
            expression = agent.routing_expression.strip
            unless expression.start_with?("{%")
              expression = "{% if #{expression} %}true{% endif %}"
            end

            template = Liquid::Template.parse(expression)
            result = template.render(agent_context)

            # Check if the result evaluates to "true" string or boolean true
            if result.strip == "true"
              matched_agents << agent
            end
          rescue StandardError => e
            Rails.logger.error("Routing error for agent #{agent.id}: #{e.message}")
          end
        end

        matched_agents
      end

      def has_creative_permission?(agent, context)
        # Searchable agents can receive any routed message
        return true if agent.searchable?

        # Non-searchable agents must have feedback permission on the creative
        creative_id = context.dig("creative", "id") || context.dig(:creative, :id)
        return false unless creative_id

        creative = Creative.find_by(id: creative_id)
        return false unless creative

        creative.has_permission?(agent, :feedback)
      end
    end
  end
end
