module Collavre
  module SystemEvents
    class Router
      def route(event_name, context)
        # Build the context for Liquid
        liquid_context = Collavre::SystemEvents::ContextBuilder.new(context).build
        liquid_context["event_name"] = event_name

        # Priority 1: Mention-based routing (exclusive)
        # If any AI agent is mentioned, ONLY route to that agent
        mentioned_agent = find_mentioned_agent(liquid_context, context)
        return [ mentioned_agent ] if mentioned_agent

        # Priority 2: Liquid expression routing (fallback)
        route_by_liquid_expression(liquid_context, context)
      end

      private

      def find_mentioned_agent(liquid_context, context)
        mentioned_user_data = liquid_context.dig("chat", "mentioned_user")
        return nil unless mentioned_user_data && mentioned_user_data["id"]

        agent = User.find_by(id: mentioned_user_data["id"])
        return nil unless agent&.ai_user?

        # Permission check for mentioned agent
        return nil unless has_creative_permission?(agent, context)

        agent
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
