# frozen_string_literal: true

module Collavre
  class ApprovalPendingError < StandardError
    attr_reader :tool_call, :task

    def initialize(message = "Tool execution requires approval", tool_call: nil, task: nil)
      @tool_call = tool_call
      @task = task
      super(message)
    end

    def tool_name
      tool_call&.name || tool_call&.dig("name")
    end

    def tool_arguments
      tool_call&.arguments || tool_call&.dig("arguments") || {}
    end

    def tool_call_id
      tool_call&.id || tool_call&.dig("id")
    end

    def to_h
      {
        tool_name: tool_name,
        tool_call_id: tool_call_id,
        arguments: tool_arguments,
        task_id: task&.id
      }
    end
  end
end
