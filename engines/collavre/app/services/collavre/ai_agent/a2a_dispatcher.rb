# frozen_string_literal: true

module Collavre
  module AiAgent
    # Handles agent-to-agent (A2A) orchestration dispatch.
    # Detects mentioned agents, records interactions for loop prevention,
    # and dispatches system events for downstream processing.
    class A2aDispatcher
      def initialize(agent:, reply_comment:, context:, workspace_user: nil)
        @agent = agent
        @reply_comment = reply_comment
        @context = context
        @workspace_user = workspace_user
      end

      # Dispatch A2A events if the response mentions any AI agents
      def dispatch
        return unless @reply_comment&.content.present?
        # An approval-action message (approve button / approved) is a human decision
        # surface and must never reach an AI agent — not even via an @mention in
        # another agent's reply. Same invariant as Comment#dispatch_to_orchestration.
        return if @reply_comment.approval_action?

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
        payload = {
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
        }
        # Always carry the resolved principal, including an explicit nil. Nil
        # means the current anchor could not prove a human identity; omitting the
        # key would let a downstream per-user CLI Proxy agent fall back to its
        # creator and execute with that person's workspace credentials.
        payload[:workspace_user_id] = @workspace_user&.id

        SystemEvents::Dispatcher.dispatch("comment_created", payload)
      end
    end
  end
end
