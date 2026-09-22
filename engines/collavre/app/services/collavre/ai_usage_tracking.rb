# frozen_string_literal: true

module Collavre
  module AiUsageTracking
    private

    def observe_usage(chunk)
      @usage_recorder&.observe(chunk)
    end

    def finalize_chat_usage(response, contents, response_content, error_message, input_tokens, output_tokens)
      # A tool still pending here raised out of the tool loop.
      finish_tool_usage(false)
      finish_usage_tracking(response)
      @last_input_tokens = input_tokens || 0
      @last_output_tokens = output_tokens || 0
      return unless @log_interactions

      log_interaction(
        messages: @conversation&.messages&.to_a || Array(contents),
        tools: @conversation&.tools&.to_a || [],
        response_content: response_content.presence, error_message: error_message,
        input_tokens: input_tokens, output_tokens: output_tokens
      )
    end

    def log_interaction(messages:, tools:, response_content:, error_message: nil, input_tokens: nil, output_tokens: nil)
      log = RubyLlmInteractionLogger.log(
        vendor: @vendor,
        model: @model,
        messages: messages,
        tools: tools,
        response_content: response_content,
        error_message: error_message,
        creative: context&.dig(:creative),
        user: context&.dig(:user),
        comment: context&.dig(:comment),
        input_tokens: input_tokens,
        output_tokens: output_tokens
      )
      @usage_recorder&.attach(log)
      log
    rescue StandardError => e
      Rails.logger.error("Failed to link LLM usage: #{e.class}: #{e.message}")
      log
    end

    def start_usage_tracking(measurement: nil)
      @tool_usage_recorder = @pending_tool_usage = nil
      @usage_recorder = LlmUsage::Recorder.new(context: context, vendor: vendor, model: model, measurement: measurement) if @log_interactions
    rescue StandardError => e
      @usage_recorder = nil
      Rails.logger.error("Failed to start LLM usage: #{e.class}: #{e.message}")
    end

    def install_usage_tracking(chat)
      chat.after_message { |response| record_usage_response(response) } if chat.respond_to?(:after_message)
    end

    def record_usage_response(response)
      @usage_recorder&.record(response)
    rescue StandardError => e
      Rails.logger.error("Failed to persist LLM usage: #{e.class}: #{e.message}")
    end

    # Called after the approval checks pass, so a call parked for approval is not counted.
    def start_tool_usage(tool_call)
      return unless @usage_recorder

      @pending_tool_usage = { name: tool_call.name, started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    end

    # Tool rows share the LLM rows' execution_id so both join by execution.
    def finish_tool_usage(succeeded)
      pending = @pending_tool_usage
      return unless pending

      @pending_tool_usage = nil
      @tool_usage_recorder ||= ToolUsage::Recorder.new(context: context, source: "internal", execution_id: @usage_recorder.execution_id)
      @tool_usage_recorder.record(tool_name: pending[:name], succeeded: succeeded, duration_ms: ToolUsage.elapsed_ms(pending[:started_at]))
    rescue StandardError => e
      Rails.logger.error("Failed to persist tool usage: #{e.class}: #{e.message}")
    end

    def finish_usage_tracking(response = nil)
      @usage_recorder&.finish(response)
    rescue StandardError => e
      Rails.logger.error("Failed to persist LLM usage: #{e.class}: #{e.message}")
    end
  end
end
