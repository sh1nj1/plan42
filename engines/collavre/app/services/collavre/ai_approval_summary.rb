# frozen_string_literal: true

module Collavre
  module AiApprovalSummary
    # Ask a follow-up question using the existing conversation context.
    # Used to generate approval summaries with full conversation history.
    # Returns the response content string, or nil on failure.
    def ask(prompt)
      return nil unless @conversation

      original_messages = close_summary_tool_round
      start_usage_tracking
      refresh_turn_boundary!(@conversation)
      # Disable tool calls for summary generation to avoid recursive approval
      @conversation.with_tools(nil)
      response = @conversation.ask(prompt)
      refresh_turn_boundary!(@conversation)
      response&.content&.strip.presence
    rescue CancelledError
      raise
    rescue StandardError => e
      # A provider timeout at the turn boundary must become the deadline that
      # caused it, not a missing summary followed by pending_approval.
      refresh_turn_boundary!(@conversation)
      Rails.logger.warn("AiClient#ask failed: #{e.class} #{e.message}")
      nil
    ensure
      finish_usage_tracking(response) if @conversation
      @conversation.messages.replace(original_messages) if original_messages
    end

    private

    # Complete the summary transcript without executing pending tools. The original
    # approval conversation is restored by #ask, including on provider failure.
    def close_summary_tool_round
      messages = @conversation.messages
      answered = messages.filter_map(&:tool_call_id)
      calls = messages.flat_map { |message| message.tool_calls&.values || [] }
      pending = calls.reject { |call| answered.include?(call.id) }
      return if pending.empty?

      original_messages = messages.dup
      pending.each do |call|
        @conversation.add_message(role: :tool, tool_call_id: call.id,
                                  content: "Awaiting human approval; not executed.")
      end
      original_messages
    end
  end
end
