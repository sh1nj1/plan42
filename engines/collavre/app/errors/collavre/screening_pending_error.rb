# frozen_string_literal: true

module Collavre
  # A turn the screeners could not answer for. It waits on the agent owner's
  # decision through the approval-gate surface (AiAgent::ScreeningApprovalHandler).
  class ScreeningPendingError < ApprovalGatePendingError
    attr_reader :content_digest, :residual, :execution_generation

    def initialize(task:, approver:, question:, content_digest:, residual: "passed", execution_generation: nil)
      super(tool_call: { "id" => "screening-#{SecureRandom.uuid}", "name" => "screening", "arguments" => {} },
            task: task, question: question, approver: approver, messages: [])
      @content_digest = content_digest
      @residual = residual
      @execution_generation = execution_generation
    end
  end
end
