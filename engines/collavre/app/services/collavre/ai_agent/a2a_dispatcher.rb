# frozen_string_literal: true

module Collavre
  module AiAgent
    # Handles agent-to-agent (A2A) orchestration dispatch.
    # Detects mentioned agents, records interactions for loop prevention,
    # and dispatches system events for downstream processing.
    class A2aDispatcher
      def initialize(agent:, reply_comment:, context:)
        @agent = agent
        @reply_comment = reply_comment
        @context = context
      end

      # Dispatch A2A events if the response mentions any AI agents
      def dispatch
        return unless @reply_comment&.content.present?

        mentioned_agents = find_mentioned_agents
        return if mentioned_agents.empty?

        creative = @reply_comment.creative
        record_interactions(mentioned_agents, creative)
        dispatch_event(creative)
      rescue StandardError => e
        Rails.logger.error("[AiAgent::A2aDispatcher] A2A dispatch failed: #{e.message}")
      end

      private

      def find_mentioned_agents
        MentionParser.resolve_all_users(@reply_comment.content).select(&:ai_user?)
      end

      def record_interactions(mentioned_agents, creative)
        return unless creative

        mentioned_agents.each do |mentioned_user|
          context = {
            "creative" => { "id" => creative.id },
            "topic" => { "id" => @reply_comment.topic_id }
          }
          Orchestration::LoopBreaker.new(context).record_interaction(
            @agent.id,
            mentioned_user.id,
            creative.id
          )
        end
      end

      def dispatch_event(creative)
        SystemEvents::Dispatcher.dispatch("comment_created", {
          comment: {
            id: @reply_comment.id,
            content: @reply_comment.content,
            user_id: @reply_comment.user_id
          },
          creative: {
            id: creative&.id,
            description: creative&.description
          },
          topic: { id: @reply_comment.topic_id },
          chat: { content: @reply_comment.content }
        })
      end
    end
  end
end
