module Collavre
  module AiAgentResolvable
    extend ActiveSupport::Concern

    private

    # Resolve AI agent using orchestration rules:
    # 1. Topic's primary agent (stored on topics table)
    # 2. Fallback: policy-level primary_agent_id (creative/global scope)
    # 3. Fallback: any AI agent with feedback permission on the creative
    def resolve_ai_agent(creative, topic_id)
      if topic_id.present?
        # Check topic's direct primary_agent_id first
        topic = Topic.find_by(id: topic_id)
        if topic&.primary_agent_id.present?
          agent = User.find_by(id: topic.primary_agent_id)
          return agent if agent&.ai_user?
        end

        # Fall back to policy-level config (creative/global scope)
        context = build_ai_agent_policy_context(creative, topic_id)
        resolver = Orchestration::PolicyResolver.new(context)
        primary_id = resolver.arbitration_config["primary_agent_id"]

        if primary_id.present?
          agent = User.find_by(id: primary_id)
          return agent if agent&.ai_user?
        end
      end

      creative.effective_origin.all_shared_users(:feedback)
        .map(&:user)
        .find(&:ai_user?)
    end

    def build_ai_agent_policy_context(creative, topic_id)
      context = {}
      context["creative"] = { "id" => creative.id }
      context["topic"] = { "id" => topic_id } if topic_id.present?
      context
    end
  end
end
