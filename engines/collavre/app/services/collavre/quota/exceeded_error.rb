# frozen_string_literal: true

module Collavre
  module Quota
    class ExceededError < StandardError
      CLAUDE_SESSION_LIMIT = /\AClaude run failed: (?:subtype=\w+: )?You['’]ve hit your 5-hour limit · resets\s/i

      attr_reader :reset_at

      def initialize(reset_at: nil)
        @reset_at = reset_at
        super("Agent session quota exhausted")
      end

      # CLI proxy SSE errors can have a synthetic HTTP status. Use the
      # envelope code and recognize the Claude adapter's specific session cap.
      def self.from_response(error)
        return unless error.respond_to?(:response) && (response = error.response)

        detail = error_detail(response.body)
        return unless detail
        message = detail["message"].to_s
        return if message.match?(/billing|credit balance|payment|account (?:disabled|deactivated|on hold)/i)

        code = detail["code"] || detail["type"]
        claude_reset = CLAUDE_SESSION_LIMIT.match(message)&.post_match
        return unless code == "insufficient_quota" || (code == "rate_limit_exceeded" && claude_reset)

        headers = response.respond_to?(:headers) ? response.headers : {}
        reset_at = RetryTime.parse(retry_header(headers)) || RetryTime.parse_claude_clock(claude_reset)
        new(reset_at: reset_at)
      end

      def self.error_detail(body)
        body = JSON.parse(body) if body.is_a?(String)
        detail = body["error"] if body.is_a?(Hash)
        detail if detail.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
      private_class_method :error_detail

      def self.retry_header(headers)
        headers&.find { |key, _| key.to_s.downcase == "retry-after" }&.last
      end
    end
  end
end
