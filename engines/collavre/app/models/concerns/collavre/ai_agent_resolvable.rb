module Collavre
  module AiAgentResolvable
    extend ActiveSupport::Concern

    private

    # Resolve AI agent using orchestration rules:
    # 1. Topic's primary agent (stored on topics table)
    # 2. Fallback: policy-level primary_agent_id (creative/global scope)
    # 3. Fallback: any chat-capable AI agent with feedback permission on the creative
    def resolve_ai_agent(creative, topic_id)
      if topic_id.present?
        # Check topic's direct primary_agent_id first
        topic = Topic.find_by(id: topic_id)
        agent = topic&.primary_agent
        return agent if agent&.supports?(:chat)
        return if topic&.session_id.present?

        # Fall back to policy-level config (creative/global scope)
        context = build_ai_agent_policy_context(creative, topic_id)
        resolver = Orchestration::PolicyResolver.new(context)
        primary_id = resolver.arbitration_config["primary_agent_id"]

        if primary_id.present?
          agent = User.find_by(id: primary_id)
          return agent if agent&.supports?(:chat)
        end
      end

      creative.effective_origin.all_shared_users(:feedback)
        .map(&:user)
        .find { |user| user.supports?(:chat) }
    end

    # Streams the comments through the agent's model and returns the generated
    # text. AiClient returns nil on error while still yielding the error text as
    # a delta, so a nil result or blank output both count as failure (nil).
    def ai_digest_comments(agent, comments, system_prompt:, creative:, topic_id:, requester:)
      client = build_client(agent, creative, topic_id, requester, system_prompt)
      conversation = comments.map do |comment|
        "#{comment.user&.name || I18n.t('collavre.comments.anonymous')}: #{comment.content}"
      end.join("\n\n")

      output = String.new
      result = client.chat([ { role: "user", text: conversation } ]) { |delta| output << delta }
      output if result && output.present?
    end

    # MergeCommentsJob always uses its own SYSTEM_PROMPT; CompressJob passes one.
    def build_client(agent, creative, topic_id, requester, system_prompt = self.class::SYSTEM_PROMPT)
      AiClient.new(
        vendor: agent.llm_vendor, model: agent.llm_model, system_prompt: system_prompt,
        llm_api_key: agent.llm_api_key || agent.creator&.llm_api_key,
        gateway_url: agent.gateway_url.presence || agent.creator&.gateway_url,
        context: { creative: creative, user: agent, requester: requester, topic_id: topic_id }
      )
    end

    def build_ai_agent_policy_context(creative, topic_id)
      context = {}
      context["creative"] = { "id" => creative.id }
      context["topic"] = { "id" => topic_id } if topic_id.present?
      context
    end
  end
end
