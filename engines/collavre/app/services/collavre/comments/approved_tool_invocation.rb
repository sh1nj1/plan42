# frozen_string_literal: true

module Collavre
  module Comments
    # Approval authorizes an invocation, never a change of principal. Keep the
    # paused agent's grants, conversation boundary, and history attribution.
    class ApprovedToolInvocation
      def self.call(task, tool_name, arguments)
        invocation = -> { ::Tools::MetaToolService.new.call(action: "call", tool_name: tool_name, arguments: arguments) }
        return invocation.call unless task

        raise ArgumentError, "Approved task has no agent" unless task.agent

        workspace_user = AiAgent::TaskWorkspaceUser.resolve(task)
        Creatives::AgentTurnHistory.call(task.agent, workspace_user, task) do
          Current.set(authoritative_permissions: true) do
            if task.creative_id && !Creatives::PermissionChecker.current_allowed?(task.creative_id, task.agent)
              raise I18n.t("collavre.comments.approve_agent_permission_denied")
            end

            invocation.call
          end
        end
      rescue StandardError => e
        Rails.logger.error("Tool execution failed: #{e.message}")
        { error: e.message }
      end
    end
  end
end
