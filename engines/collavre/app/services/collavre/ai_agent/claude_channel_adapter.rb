# frozen_string_literal: true

module Collavre
  module AiAgent
    # Adapter for Claude Channel agents that communicate via MCP (ActionCable)
    # instead of RubyLLM. Messages are delivered through AgentChannel WebSocket;
    # responses arrive asynchronously via the reply API endpoint.
    class ClaudeChannelAdapter
      class UndeliverableError < StandardError; end

      def initialize(agent:, context:, task: nil)
        @agent = agent
        @context = context
        @task = task
        @topic_id = context.dig("topic", "id")
      end

      def deliver
        unless @topic_id
          # Workflow subtasks build context without a topic (see
          # WorkflowExecutor#build_subtask_context). A Claude Channel agent
          # cannot service those — raise so AiAgentJob fails the task and the
          # parent workflow advances via fail_subtask! instead of hanging.
          raise UndeliverableError,
                "Claude Channel delivery requires a topic_id (agent=#{@agent.id})"
        end

        comment = find_comment
        payload = {
          type: "dispatch",
          agent_id: @agent.id,
          # task_id lets the MCP client echo it back via /reply so the server
          # can complete the exact dispatched task even when topic concurrency
          # > 1 allows multiple in-flight delegated tasks per topic.
          task_id: @task&.id,
          comment: {
            id: @context.dig("comment", "id"),
            content: @context.dig("comment", "content"),
            author_id: @context.dig("sender", "id") || @context.dig("comment", "user_id"),
            author_name: @context.dig("sender", "name") || comment&.user&.display_name,
            topic_id: @topic_id,
            creative_id: @context.dig("creative", "id"),
            created_at: comment&.created_at&.iso8601
          }
        }

        # Per-agent stream is the source of truth for MCP plugin clients:
        # they subscribe once by agent_id and receive every dispatch routed
        # to this agent regardless of which topic triggered it. The per-topic
        # stream is kept for legacy/UI viewers but is not how Claude Channel
        # plugins consume dispatches.
        AgentChannel.broadcast_to_agent(@agent.id, payload)
        AgentChannel.broadcast_to_topic(@topic_id, payload)
      end

      private

      def find_comment
        comment_id = @context.dig("comment", "id")
        comment_id ? Comment.find_by(id: comment_id) : nil
      end
    end
  end
end
