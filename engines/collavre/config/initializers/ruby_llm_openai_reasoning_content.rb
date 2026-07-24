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
    # Hosted OpenAI tolerates the redundant key, but some strict
    # OpenAI-compatible gateways reject it. Cerebras is the concrete case we hit:
    # its AssistantMessage schema defines `reasoning` but not `reasoning_content`,
    # so the tool-result follow-up request (the second call in a tool loop, the
    # first that replays an assistant turn) fails with a 400 BadRequest. The
    # error is doubly opaque because RubyLLM's parse_error cannot read Cerebras's
    # non-standard error body and falls back to the generic
    # "Invalid request - please check your input".
    #
    # This is NOT safe to apply to every custom gateway: the opposite failure
    # exists. DeepSeek's thinking mode (default-on for its reasoning models)
    # *requires* `reasoning_content` to be replayed on the assistant turn, and
    # returns 400 "The reasoning_content in the thinking mode must be passed
    # back to the API" when it is missing. So the removal is scoped to an
    # explicit denylist of hosts we have confirmed reject the key; every other
    # target — hosted OpenAI, DeepSeek, Ollama/LM Studio, and unknown gateways —
    # keeps `reasoning_content` untouched.
    #
    # Upstream has no fix as of 1.16.0; revisit and remove this patch if a later
    # ruby_llm release makes the second key gateway-aware.
    module OpenAIDropReasoningContent
      # OpenAI-compatible gateway hosts whose chat-completions schema rejects the
      # non-standard `reasoning_content` key. Add a host here only after
      # confirming it 400s on the replayed key (do NOT add DeepSeek — it needs
      # the key). Matched against the exact parsed host of `openai_api_base`.
      STRICT_HOSTS_REJECTING_REASONING_CONTENT = %w[api.cerebras.ai].freeze

      def format_thinking(msg)
        payload = super
        return payload unless payload.is_a?(Hash)
        return payload unless gateway_rejects_reasoning_content?

        payload.delete(:reasoning_content)
        payload
      end

      private

      # True only when the configured gateway host is on the known-reject
      # denylist. An absent, unparseable, or unlisted host returns false so the
      # key is preserved — the safe default, since dropping it breaks gateways
      # (e.g. DeepSeek) that require it.
      def gateway_rejects_reasoning_content?
        host = openai_base_host
        return false if host.nil?

        STRICT_HOSTS_REJECTING_REASONING_CONTENT.include?(host)
      end

      def openai_base_host
        base = config&.openai_api_base.to_s
        return nil if base.blank?

        URI.parse(base).host&.downcase
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

RubyLLM::Providers::OpenAI.prepend(Collavre::RubyLlmPatches::OpenAIDropReasoningContent)
