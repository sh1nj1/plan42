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
      stored as written and may use Markdown. An agent cannot post to the same
      primary-agent topic it is currently handling; continue that work in the
      current turn instead.

      Requires feedback permission or better on the topic's creative. Archived
      creatives, archived topics, and an inbox's reserved System topic do not
      accept messages through this tool.
    DESC

    tool_param :topic_id, description: "The topic to post the message to."
    tool_param :content, description: "The public message body or initial instruction. Markdown is supported."

    sig { params(topic_id: Integer, content: String).returns(T::Hash[Symbol, T.untyped]) }
    def call(topic_id:, content:)
      user = Current.user || raise("Current.user is required")
      topic = Topic.find(topic_id)
      TopicAuthorizer.authorize_feedback!(topic, user: user)
      principal = workspace_user(user)

      comment = create_comment(topic, content, user, principal)
      dispatch_agent_message(comment, user, principal) if user.ai_user?

      serialize(comment)
    end

    private

    def create_comment(topic, content, user, principal)
      Comment.transaction do
        topic.lock!
        TopicAuthorizer.authorize_feedback!(topic, user: user)
        reject_closed_topic!(topic)
        reject_unrunnable_self_dispatch!(topic, user, principal)

        topic.comments.create!(
          creative: topic.creative,
          content: content,
          user: user,
          private: false,
          skip_dispatch: user.ai_user?
        )
      end
    end

    def reject_closed_topic!(topic)
      raise ArgumentError, "Archived creatives do not accept topic messages." if topic.creative.archived?
      raise ArgumentError, "Archived topics do not accept messages." if topic.archived?
      return unless topic.creative.inbox? && topic.name == Creative::SYSTEM_TOPIC_NAME

      raise ArgumentError, "The inbox System topic does not accept user-authored messages."
    end

    def reject_unrunnable_self_dispatch!(topic, user, principal)
      return unless user.ai_user? && topic.primary_agent_id == user.id
      return if principal && Current.agent_turn&.dig(:task)&.topic_id != topic.id

      raise ArgumentError, "An agent cannot dispatch a topic message to its own current topic."
    end

    def dispatch_agent_message(comment, user, principal)
      payload = comment.dispatch_payload.merge(workspace_user_id: principal&.id)
      # A coordinator may fan itself out into two topic slots. Treat the
      # carried human as that self-dispatch's sender so the downstream turn
      # reports to the requester instead of @mentioning itself and opening a
      # fresh A2A turn on completion.
      if comment.topic.primary_agent_id == user.id && principal
        payload[:sender] = SystemEvents::ContextBuilder.sender_context_for(principal)
      end
      record_interactions(payload, user, comment.creative_id)
      parent = SystemEvents::Envelope.in(Current.agent_turn&.dig(:task)&.trigger_event_payload)
      SystemEvents::Dispatcher.dispatch("comment_created", payload, source: "a2a", parent: parent)
    end

    def record_interactions(payload, user, creative_id)
      context = SystemEvents::ContextBuilder.new(payload).build
      Orchestration::Matcher.new(context).match.each do |agent|
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
