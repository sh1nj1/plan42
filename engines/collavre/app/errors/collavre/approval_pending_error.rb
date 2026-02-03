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
      return nil unless tool_call

      if tool_call.respond_to?(:name)
        tool_call.name
      elsif tool_call.is_a?(Hash)
        tool_call["name"] || tool_call[:name]
      end
    end

    def tool_arguments
      return {} unless tool_call

      if tool_call.respond_to?(:arguments)
        tool_call.arguments
      elsif tool_call.is_a?(Hash)
        tool_call["arguments"] || tool_call[:arguments] || {}
      else
        {}
      end
    end

    def tool_call_id
      return nil unless tool_call

      if tool_call.respond_to?(:id)
        tool_call.id
      elsif tool_call.is_a?(Hash)
        tool_call["id"] || tool_call[:id]
      end
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
