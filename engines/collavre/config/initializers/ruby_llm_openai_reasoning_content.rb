# frozen_string_literal: true

require "uri"

return unless defined?(RubyLLM::Providers::OpenAI)

module Collavre
  module RubyLlmPatches
    # RubyLLM (through the current 1.16.0) serializes a replayed assistant
    # "thinking" block into BOTH `reasoning` and `reasoning_content` on the
    # OpenAI-format request payload — see
    # RubyLLM::Providers::OpenAI::Chat#format_thinking, which sets the two keys
    # to the same value for cross-vendor compatibility (DeepSeek reads
    # `reasoning_content`; others read `reasoning`).
    #
    # Hosted OpenAI tolerates the redundant key, but strict OpenAI-compatible
    # gateways reject it. Cerebras is the concrete case we hit: its
    # AssistantMessage schema defines `reasoning` but not `reasoning_content`, so
    # the tool-result follow-up request (the second call in a tool loop, the
    # first that replays an assistant turn) fails with a 400 BadRequest. The
    # error is doubly opaque because RubyLLM's parse_error cannot read Cerebras's
    # non-standard error body and falls back to the generic
    # "Invalid request - please check your input".
    #
    # Fix: drop `reasoning_content` only when a custom gateway is configured, so
    # hosted OpenAI requests stay byte-identical. `reasoning` is kept because it
    # is the field Cerebras (and the OpenAI format itself) documents, and it
    # carries useful replayed context. Collavre's other gateways (Ollama,
    # LM Studio) ignore unknown message fields, so removing `reasoning_content`
    # is safe for them too.
    #
    # Upstream has no fix as of 1.16.0; revisit and remove this patch if a later
    # ruby_llm release makes the second key gateway-aware.
    module OpenAIDropReasoningContent
      def format_thinking(msg)
        payload = super
        return payload unless payload.is_a?(Hash)
        return payload unless custom_openai_gateway?

        payload.delete(:reasoning_content)
        payload
      end

      private

      def custom_openai_gateway?
        base = config&.openai_api_base.to_s
        return false unless base.present?

        uri = URI.parse(base)
        !(uri.is_a?(URI::HTTPS) && uri.host == "api.openai.com")
      rescue URI::InvalidURIError
        true
      end
    end
  end
end

RubyLLM::Providers::OpenAI.prepend(Collavre::RubyLlmPatches::OpenAIDropReasoningContent)
