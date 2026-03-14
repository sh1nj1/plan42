# frozen_string_literal: true

module Collavre
  module AiAgent
    # Generates a human-readable summary of a tool call for approval review.
    # Uses AI to create a concise description so approvers can quickly
    # understand what they're approving without parsing raw JSON arguments.
    class ApprovalSummaryGenerator
      SUMMARY_MODEL = "gemini-2.0-flash"

      SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a concise technical summarizer. Given a tool call (name + arguments),
        produce a 1-2 sentence summary of what this tool will do.
        Be specific: mention key parameters, target resources, and the intended effect.
        Respond in the same language as the context provided (default: English).
        Do NOT include any preamble, markdown formatting, or extra explanation.
      PROMPT

      def initialize(tool_name:, arguments:, creative: nil)
        @tool_name = tool_name
        @arguments = arguments || {}
        @creative = creative
      end

      def generate
        prompt = build_prompt
        response = call_llm(prompt)
        response&.strip.presence
      rescue StandardError => e
        Rails.logger.warn("ApprovalSummaryGenerator failed: #{e.class} #{e.message}")
        nil
      end

      private

      def build_prompt
        parts = []
        parts << "Tool: #{@tool_name}"
        parts << "Arguments:\n```json\n#{JSON.pretty_generate(@arguments)}\n```"

        if @creative
          parts << "Context: This tool is being called in the context of creative \"#{@creative.description&.truncate(200)}\""
        end

        parts.join("\n\n")
      end

      def call_llm(prompt)
        api_key = ENV["GEMINI_API_KEY"]
        return nil if api_key.blank?

        chat = RubyLLM.context { |config| config.gemini_api_key = api_key }
                       .chat(model: SUMMARY_MODEL)
        chat.with_instructions(SYSTEM_PROMPT)
        response = chat.ask(prompt)
        response&.content
      end
    end
  end
end
