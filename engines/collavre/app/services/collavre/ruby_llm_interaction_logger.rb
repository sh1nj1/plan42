module Collavre
  # frozen_string_literal: true
  
  class RubyLlmInteractionLogger
    class << self
      def log(vendor:, model:, messages:, tools: [], response_content: nil, error_message: nil, activity: "llm_query", creative: nil, user: nil, comment: nil, input_tokens: nil, output_tokens: nil)
        ActivityLog.create!(
          activity: activity,
          creative: creative,
          user: user,
          comment: comment,
          log: {
            vendor: vendor.presence || "unknown",
            model: model.to_s,
            messages: safe_json(messages || []),
            tools: safe_json(tools || []),
            response_content: response_content,
            error_message: error_message,
            input_tokens: input_tokens,
            output_tokens: output_tokens
          }
        )
      rescue StandardError => e
        Rails.logger.error("Failed to persist activity log: #{e.class} #{e.message}")
      end
  
      private
  
      def safe_json(value)
        JSON.parse(value.to_json)
      end
    end
  end
end
