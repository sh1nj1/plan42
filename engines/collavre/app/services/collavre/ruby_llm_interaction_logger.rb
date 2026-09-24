module Collavre
  # frozen_string_literal: true

  class RubyLlmInteractionLogger
    class << self
      def log(vendor:, model:, messages:, tools: [], activity: "llm_query", creative: nil, user: nil, comment: nil, **details)
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
            response_content: details[:response_content],
            error_message: details[:error_message],
            input_tokens: details[:input_tokens],
            output_tokens: details[:output_tokens]
          }.merge(details[:run_options] ? details.slice(:run_options) : {})
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
