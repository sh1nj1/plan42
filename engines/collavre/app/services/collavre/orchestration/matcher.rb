# frozen_string_literal: true

module Collavre
  module Orchestration
    # Matcher determines which AI agents are qualified to respond to an event.
    #
    # Matching strategies (in priority order):
    # 1. Mention-based: If a user is @mentioned, route exclusively to that user
    #    - If mentioned user is AI agent → route to that agent only
    #    - If mentioned user is human → no AI agents respond
    # 2. Expression-based: Evaluate each agent's routing_expression (Liquid)
    #
    # Permission checks:
    # - All agents need feedback permission on the creative to respond
    # - searchable only affects discoverability, not response permission
    #
    class Matcher
      def initialize(context)
        @context = context
      end

      # Returns Array of User (AI agents) that are qualified to respond
      def match
        # Priority 1: Mention-based routing (exclusive)
        mentioned_result = match_by_mention
        return mentioned_result unless mentioned_result.nil?

        # Priority 2: Liquid expression routing (fallback)
        match_by_expression
      end

      private

      # Returns Array of agents if mention found, nil if no mention
      # When mention IS found, this is exclusive routing
      def match_by_mention
        mentioned_user_data = @context.dig("chat", "mentioned_user")
        return nil unless mentioned_user_data && mentioned_user_data["id"]

        mentioned_user = User.find_by(id: mentioned_user_data["id"])
        return nil unless mentioned_user

        # Mention found — exclusive routing
        # If mentioned user is not an AI agent, no AI agents should receive it
        return [] unless mentioned_user.ai_user?

        # Permission check for mentioned AI agent
        return [] unless has_creative_permission?(mentioned_user)

        # Inbox confinement applies to mentions too: a live Claude Channel
        # session agent must not be pulled into an ordinary inbox topic, even by
        # an explicit @mention (see #eligible_in_inbox?).
        return [] unless eligible_in_inbox?(mentioned_user)

        [ mentioned_user ]
      end

      def match_by_expression
        # Find all AI agents with routing expressions
        # Order by id for consistent ordering (important for round_robin strategy)
        agents = User.where.not(llm_vendor: nil).where.not(routing_expression: [ nil, "" ]).order(:id)

        agents.select do |agent|
          next false unless has_creative_permission?(agent)
          next false unless eligible_in_inbox?(agent)

          evaluate_routing_expression(agent)
        end
      end

      # A Claude Channel session agent holds inbox-wide :feedback +
      # routing_expression="true", so within the user's Inbox it would otherwise
      # match EVERY topic. Confine it to its own registered session topic (the
      # topic it is primary_agent on, carrying a session_id) so ordinary inbox
      # topics — Main, Content, user threads — stay identical to a normal topic
      # and are never absorbed by a live session. Only the inbox is affected: on
      # work/project creatives the agent still matches via routing_expression.
      def eligible_in_inbox?(agent)
        return true unless matched_creative&.inbox?
        return true unless agent.claude_channel_agent?

        matched_topic&.session_id.present? && matched_topic.primary_agent_id == agent.id
      end

      def evaluate_routing_expression(agent)
        expression = agent.routing_expression.strip

        # Wrap in if block if not already a Liquid tag
        unless expression.start_with?("{%")
          expression = "{% if #{expression} %}true{% endif %}"
        end

        # Add agent to context for self-reference
        agent_context = @context.merge("agent" => agent.as_json(only: [ :id, :name, :email ]))

        template = Liquid::Template.parse(expression)
        result = template.render(agent_context)

        result.strip == "true"
      rescue StandardError => e
        Rails.logger.error("[Matcher] Routing error for agent #{agent.id}: #{e.message}")
        false
      end

      def has_creative_permission?(agent)
        # All agents need feedback permission on the creative to respond
        # searchable only affects discoverability, not response permission
        creative = matched_creative
        return false unless creative

        creative.has_permission?(agent, :feedback)
      end

      def matched_creative
        return @matched_creative if defined?(@matched_creative)

        creative_id = @context.dig("creative", "id") || @context.dig(:creative, :id)
        @matched_creative = creative_id && Creative.find_by(id: creative_id)
      end

      def matched_topic
        return @matched_topic if defined?(@matched_topic)

        topic_id = @context.dig("topic", "id") || @context.dig(:topic, :id)
        @matched_topic = topic_id && Topic.find_by(id: topic_id)
      end
    end
  end
end
