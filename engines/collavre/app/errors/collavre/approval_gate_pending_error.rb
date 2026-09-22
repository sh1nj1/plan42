# frozen_string_literal: true

module Collavre
  class ApprovalGatePendingError < ApprovalPendingError
    attr_reader :question, :approver, :messages

    def initialize(tool_call:, task:, question:, approver:, messages:)
      super(tool_call: tool_call, task: task)
      @question, @approver, @messages = question, approver, messages
    end
  end
end
