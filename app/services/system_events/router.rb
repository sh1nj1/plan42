module SystemEvents
  class Router
    def route(event_name, context)
      # Build the context for Liquid
      liquid_context = ContextBuilder.new(context).build
      liquid_context["event_name"] = event_name

      # Find all AI agents
      agents = User.where.not(llm_vendor: nil)

      matched_agents = []

      agents.each do |agent|
        next if agent.routing_expression.blank?

        # Permission Check
        # If agent is not searchable, it must have feedback permission on the creative
        unless agent.searchable?
          creative_id = context.dig("creative", "id") || context.dig(:creative, :id)
          if creative_id
            creative = Creative.find_by(id: creative_id)
            if creative
              # Check for feedback permission (which implies read access)
              # has_permission? checks for the specific permission or higher
              unless creative.has_permission?(agent, :feedback)
                # Rails.logger.info "Agent #{agent.id} skipped: No feedback permission on Creative #{creative.id}"
                next
              end
            else
              # If creative ID is present but not found, skip for safety
              next
            end
          else
            # If no creative context, we might skip or allow depending on policy.
            # Assuming 'chat.creative' implies creative context is required for this check.
            # If it's a global event without creative, maybe searchable check isn't needed?
            # But the user said "must have feedback permission on the chat.creative".
            # If there is no creative, we can't check permission, so we should probably skip to be safe
            # unless it's a purely global event. But for now, let's skip.
            next
          end
        end

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
  end
end
