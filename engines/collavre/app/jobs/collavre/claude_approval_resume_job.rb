# frozen_string_literal: true

module Collavre
  class ClaudeApprovalResumeJob < ApprovalContinuationJob
    private

    def continuation_payload(comment)
      JSON.parse(comment.action) if comment.claude_channel_approval_request?
    end

    def eligible_agent?(agent) = agent.claude_channel_agent?
    def request_context_key = "claude_approval_request_id"
    def event_name = "claude_channel_approval"
  end
end
