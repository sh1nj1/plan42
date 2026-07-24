# frozen_string_literal: true

module Collavre
  module AiAgent
    # Handles tool-execution approval flow when an AI agent
    # invokes a tool that requires human approval.
    class ApprovalHandler
      def initialize(task:, agent:, context:, creative: nil, reply_comment: nil)
        @task = task
        @agent = agent
        @context = context
        @creative = creative
        @reply_comment = reply_comment
      end

      def handle(error, summary: nil)
        cleanup_placeholder

        update_task(error)

        broadcast_pending_approval

        log_action(error)

        create_approval_comment(error, summary: summary)
      end

      private

      def cleanup_placeholder
        @reply_comment&.destroy! if @reply_comment&.content == Comment::STREAMING_PLACEHOLDER_CONTENT
      end

      # The agent has stopped producing output, but the task has not finished:
      # it holds its topic slot until the tool call is approved or rejected, and
      # TasksController#cancel still accepts it. Broadcasting "idle" here made
      # the client drop the task and stop polling, so the pending_approval status
      # this method announces was never observed and Stop disappeared on the one
      # turn that is waiting on the user. Sent after update_task so a client that
      # reacts by polling reads the status this payload claims.
      def broadcast_pending_approval
        return unless @creative

        CommentsPresenceChannel.broadcast_agent_status(
          @creative.effective_origin.id,
          status: "pending_approval",
          agent_id: @agent.id,
          agent_name: @agent.display_name,
          task_id: @task.id,
          source_creative_id: @creative.id
        )
      end

      def update_task(error)
        @task.update!(
          status: "pending_approval",
          pending_tool_call: {
            tool_name: error.tool_name,
            tool_call_id: error.tool_call_id,
            arguments: error.tool_arguments,
            requested_at: Time.current.iso8601
          }
        )
      end

      def log_action(error)
        @task.task_actions.create!(
          action_type: "pending_approval",
          payload: error.to_h,
          status: "done"
        )
      end

      def create_approval_comment(error, summary: nil)
        return unless @creative

        approver = @creative.user || User.find_by(id: @context.dig("comment", "user_id"))
        return unless approver

        action_payload = {
          action: "execute_tool",
          tool_name: error.tool_name,
          arguments: error.tool_arguments,
          resume: {
            task_id: @task.id,
            tool_call_id: error.tool_call_id
          }
        }

        args_display = if error.tool_arguments.present?
                         JSON.pretty_generate(error.tool_arguments)
        else
                         I18n.t("collavre.ai_agent.approval.no_arguments")
        end

        content = I18n.t(
          "collavre.ai_agent.approval.message",
          tool_name: error.tool_name,
          arguments: args_display
        )

        if summary.present?
          content += "\n#{I18n.t('collavre.ai_agent.approval.summary_header')}\n#{summary}\n"
        end

        original_comment = Comment.find_by(id: @context.dig("comment", "id"))
        topic_id = original_comment&.topic_id

        Comment.create!(
          creative: @creative,
          content: content,
          user: @agent,
          approver: approver,
          action: JSON.pretty_generate(action_payload),
          topic_id: topic_id,
          private: false
        )
      end
    end
  end
end
