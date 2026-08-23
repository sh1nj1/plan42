# frozen_string_literal: true

module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Posts one public message into an existing topic and starts the topic's
  # normal orchestration route.
  class TopicMessageCreateService
    extend T::Sig
    extend ToolMeta

    tool_name "topic_message_create"
    tool_description <<~DESC.strip
      Post a public message to an existing Collavre topic.

      Use this after topic_create to give the topic's primary agent its initial
      instruction. A primary-agent pin is exclusive, so an ambient message here
      starts that agent and no other agent. Messages posted to different topics
      can run concurrently; messages posted to the same topic queue behind the
      topic's current work.

      The caller remains the message author. Human-authored messages use normal
      comment dispatch, while agent-authored messages are dispatched as A2A work
      so an agent can fan work out without impersonating a human. The content is
      stored as written and may use Markdown. An agent cannot post to the topic
      it is currently handling; continue that work in the current turn instead.

      Requires feedback permission or better on the topic's creative. Archived
      creatives, archived topics, and an inbox's reserved System topic do not
      accept messages through this tool.
    DESC

    tool_param :topic_id, description: "The topic to post the message to."
    tool_param :content, description: "The public message body or initial instruction. Markdown is supported."

    sig { params(topic_id: Integer, content: String).returns(T::Hash[Symbol, T.untyped]) }
    def call(topic_id:, content:)
      user = Current.user || raise(I18n.t("collavre.tools.topic_message_create.errors.current_user_required"))
      topic = Topic.find(topic_id)
      TopicAuthorizer.authorize_feedback!(topic, user: user)
      principal = workspace_user(user)

      comment, selection = create_comment(topic, content, user, principal)
      dispatch_agent_message(comment, user, principal, selection) if user.ai_user?

      serialize(comment)
    end

    private

    def create_comment(topic, content, user, principal)
      Comment.transaction do
        topic.lock!
        TopicAuthorizer.authorize_feedback!(topic, user: user)
        reject_closed_topic!(topic)
        reject_unrunnable_self_dispatch!(topic, user, principal)

        comment = topic.comments.create!(
          creative: topic.creative,
          content: content,
          user: user,
          private: false,
          skip_dispatch: user.ai_user?
        )
        selection = prepare_selection(comment, principal) if user.ai_user?
        reject_selected_self_route!(selection&.agents, user, principal)

        [ comment, selection ]
      end
    end

    def reject_closed_topic!(topic)
      if topic.creative.archived?
        raise ArgumentError, I18n.t("collavre.tools.topic_message_create.errors.archived_creative")
      end
      if topic.archived?
        raise ArgumentError, I18n.t("collavre.tools.topic_message_create.errors.archived_topic")
      end
      return unless topic.creative.inbox? && topic.name == Creative::SYSTEM_TOPIC_NAME

      raise ArgumentError, I18n.t("collavre.tools.topic_message_create.errors.system_topic")
    end

    def reject_unrunnable_self_dispatch!(topic, user, principal)
      return unless user.ai_user?

      same_topic = Current.agent_turn&.dig(:task)&.topic_id == topic.id
      return unless same_topic || (principal.nil? && topic.primary_agent_id == user.id)

      raise ArgumentError, I18n.t("collavre.tools.topic_message_create.errors.current_topic")
    end

    def prepare_selection(comment, principal)
      Orchestration::AgentOrchestrator.prepare_selection(
        "comment_created", dispatch_payload(comment, principal)
      )
    end

    def dispatch_agent_message(comment, user, principal, selection)
      selected_agents = selection.agents
      record_interactions(selected_agents, user, comment.creative_id)
      context_for = lambda do |agent|
        next {} unless agent.id == user.id && principal

        { "sender" => SystemEvents::ContextBuilder.sender_context_for(principal) }
      end
      payload = dispatch_payload(comment, principal)
      if selected_agents.any? { |agent| agent.id == user.id }
        payload[Orchestration::DeferredTriggerScope::SELF_AUTHORED_COMMENT_ID_KEY] = comment.id
      end
      SystemEvents::Dispatcher.dispatch(
        "comment_created", payload, source: "a2a", parent: parent_envelope,
        selection: selection, context_for: context_for
      )
    end

    def dispatch_payload(comment, principal)
      comment.dispatch_payload.merge(workspace_user_id: principal&.id)
    end

    def reject_selected_self_route!(selected_agents, user, principal)
      return if selected_agents.nil?

      self_selected = selected_agents.any? { |agent| agent.id == user.id }
      return unless self_selected && principal.nil?

      raise ArgumentError, I18n.t("collavre.tools.topic_message_create.errors.self_route")
    end

    def parent_envelope
      SystemEvents::Envelope.in(Current.agent_turn&.dig(:task)&.trigger_event_payload)
    end

    def record_interactions(selected_agents, user, creative_id)
      context = { "creative" => { "id" => creative_id } }
      selected_agents.each do |agent|
        next if agent.id == user.id

        Orchestration::LoopBreaker.new(context).record_interaction(user.id, agent.id, creative_id)
      end
    end

    def workspace_user(user)
      return Current.agent_turn[:user] if Current.agent_turn

      creator = user.creator
      creator if creator && !creator.ai_user?
    end

    def serialize(comment)
      {
        id: comment.id,
        topic_id: comment.topic_id,
        creative_id: comment.creative_id,
        content: comment.content,
        author: { id: comment.user_id, name: comment.user.display_name },
        created_at: comment.created_at.iso8601
      }
    end
  end
end
end
