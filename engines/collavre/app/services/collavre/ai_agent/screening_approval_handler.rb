# frozen_string_literal: true

module Collavre
  module AiAgent
    # Pauses a flagged turn or a turn the screeners could not answer for. Same approve/deny
    # surface as an approval gate; the pending record carries what was asked
    # about so Screening::TurnGuard delivers only that content on approval.
    class ScreeningApprovalHandler < ApprovalGateHandler
      private

      def validate_attempt!(error)
        super
        raise CancelledError if Orchestration::ExecutionFence.superseded?(@task, error.execution_generation)
      end

      def update_task(error)
        @task.update!(status: "pending_approval", pending_tool_call: {
          kind: Screening::PENDING_KIND, tool_name: error.tool_name, tool_call_id: error.tool_call_id,
          content_digest: error.content_digest, residual: error.residual, approver_id: error.approver.id,
          policy_version: Screening::POLICY_VERSION,
          requested_at: Time.current.iso8601
        })
      end
    end
  end
end
