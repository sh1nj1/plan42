# frozen_string_literal: true

module Collavre
  class AsyncApprovalResumeJob < ApprovalContinuationJob
    private

    def continuation_payload(comment)
      payload = comment.approval_gate_action
      return unless payload&.dig("mode") == "async" && payload["decision"]

      payload.merge(payload["decision"]).merge(
        "origin_task_id" => payload["task_id"], "turn_finished" => true, "question" => comment.content
      )
    end

    def eligible_agent?(agent) = agent.cli_proxy_agent?
    def request_context_key = "async_approval_request_id"
    def event_name = "async_approval"
  end
end
