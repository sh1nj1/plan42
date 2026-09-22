# frozen_string_literal: true

module Collavre
  module AiAgent
    class ApprovalGateHandler < ApprovalHandler
      def handle(error, summary: nil)
        @task.with_lock do
          raise CancelledError unless @task.running?
          super
        end
      end

      private

      def update_task(error)
        @task.update!(status: "pending_approval", pending_tool_call: {
          kind: "approval_gate", tool_name: error.tool_name, tool_call_id: error.tool_call_id,
          arguments: error.tool_arguments, messages: error.messages,
          requested_at: Time.current.iso8601
        })
      end

      def create_approval_comment(error, summary: nil)
        Comment.create!(
          creative: @creative, topic_id: @task.topic_id,
          user: @agent, approver: error.approver, private: false,
          content: error.question,
          action: { action: "approval_gate", task_id: @task.id, tool_call_id: error.tool_call_id }.to_json
        )
      end
    end
  end
end
