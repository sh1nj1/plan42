# frozen_string_literal: true

module Collavre
  module Tools
    class AsyncApprovalRequest
      def call(task_id:, question:, approver_user_id: nil)
        task = Task.find_by(id: task_id)
        task&.with_lock do
          authorize!(task)
          approver_id = approver_user_id || AiAgent::TaskWorkspaceUser.resolve(task)&.id || 0
          approver = ApprovalRequestService.approver!(task, question, approver_id)
          gate = task.async_approval_gates.first || create_gate(task, question, approver)
          return { status: "pending", request_id: gate.approval_gate_action["request_id"],
                   question: gate.content, instruction: I18n.t("collavre.approval_gate.async_pending") }
        end
        raise ArgumentError, I18n.t("collavre.approval_gate.invalid_task")
      end

      private

      def authorize!(task)
        caller = Current.user
        unless caller && task.running? && task.agent.cli_proxy_agent? &&
            authorized_caller?(task, caller) &&
            Topic.exists?(id: task.topic_id, creative_id: task.creative_id)
          raise ArgumentError, I18n.t("collavre.approval_gate.invalid_task")
        end
        TopicAuthorizer.authorize_creative!(task.creative, :feedback, user: caller)
        TopicAuthorizer.authorize_creative!(task.creative, :feedback, user: task.agent)
      end

      def authorized_caller?(task, caller)
        workspace = Current.mcp_agent_workspace
        return task.agent == caller || task.agent.created_by_id == caller.id unless workspace

        workspace.agent_id == task.agent_id && (workspace.user || workspace.agent) == caller &&
          (workspace.user_id.nil? || workspace_principal(task) == caller)
      end

      def workspace_principal(task)
        principal = AiAgent::TaskWorkspaceUser.resolve(task)
        return principal if task.trigger_event_payload&.key?("workspace_user_id")

        principal || task.agent.creator
      end

      def create_gate(task, question, approver)
        Comment.create!(creative: task.creative, topic_id: task.topic_id, user: task.agent,
          approver: approver, content: question, private: false, async_approval_task_id: task.id,
          action: { action: "approval_gate", mode: "async", task_id: task.id,
                    request_id: SecureRandom.uuid }.to_json)
      end
    end
  end
end
