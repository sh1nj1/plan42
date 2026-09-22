# frozen_string_literal: true

module Collavre
  class LlmUsage
    class TokenNormalizer
      FIELDS = { input_tokens: :input_tokens, output_tokens: :output_tokens,
                 cache_read_tokens: :cached_tokens, cache_write_tokens: :cache_creation_tokens }.freeze

      def self.parts(response)
        FIELDS.to_h do |key, method|
          value = response.public_send(method) if response.respond_to?(method)
          [ key, value.is_a?(Integer) && value >= 0 ? value : nil ]
        end
      end

      def self.normalize(parts, raw_usage = {}, vendor: nil)
        parts = parts.dup
        if %w[openai cli_proxy].include?(vendor) && parts[:cache_write_tokens] == 0 && !raw_usage.dig("prompt_tokens_details", "cache_write_tokens")
          parts[:cache_write_tokens] = nil
        end
        input = parts[:input_tokens]
        total = input && input + parts[:cache_read_tokens].to_i + parts[:cache_write_tokens].to_i
        parts.merge(input_tokens: total, raw_usage: { "ruby_llm" => parts, "provider" => raw_usage,
                                                   "input_semantics" => "uncached_plus_cache" })
      end

      # Keep only provider usage, never prompts, tool arguments, or credentials.
      def self.raw_usage(response)
        raw = response.raw if response.respond_to?(:raw)
        body = raw.respond_to?(:body) ? raw.body : raw
        return usage_from(body) if body.is_a?(Hash)
        return {} unless body.is_a?(String)

        if body.lstrip.start_with?("{")
          usage_from(JSON.parse(body))
        else
          body.lines.grep(/^data: /).each_with_object({}) do |line, usage|
            usage.merge!(usage_from(JSON.parse(line.delete_prefix("data: "))))
          rescue JSON::ParserError
            next
          end
        end
      rescue JSON::ParserError
        {}
      end

      def self.usage_from(body)
        value = body["usage"] || body["usageMetadata"] || body.dig("message", "usage")
        value.is_a?(Hash) ? value : {}
      end
    end
  end
end
