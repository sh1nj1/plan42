# frozen_string_literal: true

module Collavre
  module Quota
    class ExceededError < StandardError
      attr_reader :reset_at

      def initialize(reset_at: nil)
        @reset_at = reset_at
        super("Agent session quota exhausted")
      end

      # RubyLLM maps SSE error envelopes to HTTP 400. Inspect the machine code,
      # not the transport status or exception message. Only CLI proxy callers
      # use this classifier: ordinary API billing exhaustion is not a session.
      def self.from_response(error)
        return unless error.respond_to?(:response) && (response = error.response)

        body = response.body
        body = JSON.parse(body) if body.is_a?(String)
        detail = body.is_a?(Hash) && body["error"]
        return unless detail.is_a?(Hash)
        return unless (detail["code"] || detail["type"]) == "insufficient_quota"
        return if detail["message"].to_s.match?(/billing|credit balance|payment|account (?:disabled|deactivated|on hold)/i)

        headers = response.respond_to?(:headers) ? response.headers : {}
        new(reset_at: RetryTime.parse(retry_header(headers)))
      rescue JSON::ParserError
        nil
      end

      def self.retry_header(headers)
        headers&.find { |key, _| key.to_s.downcase == "retry-after" }&.last
      end
    end
  end
end
