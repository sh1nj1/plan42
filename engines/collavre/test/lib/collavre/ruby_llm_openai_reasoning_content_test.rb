# frozen_string_literal: true

require "test_helper"

module Collavre
  # Guards the initializer patch that stops RubyLLM's OpenAI provider from
  # sending the non-schema `reasoning_content` field to gateways whose schema
  # rejects it (e.g. Cerebras, which 400s on the tool-result follow-up request)
  # — while preserving it for gateways that require it (e.g. DeepSeek thinking
  # mode) and for hosted OpenAI.
  class RubyLlmOpenaiReasoningContentTest < ActiveSupport::TestCase
    ThinkingDouble = Struct.new(:text, :signature)
    MessageDouble = Struct.new(:role, :thinking)

    # Build a real provider instance without running #initialize, which would
    # open a Faraday connection and demand an API key. We only exercise the
    # payload-shaping method, so an allocated instance with an injected config is
    # enough — and it keeps the real prepended method-resolution chain intact.
    def provider_for(openai_api_base)
      config = RubyLLM::Configuration.new
      config.openai_api_base = openai_api_base
      RubyLLM::Providers::OpenAI.allocate.tap do |provider|
        provider.instance_variable_set(:@config, config)
      end
    end

    def assistant_message(text: "chain of thought")
      MessageDouble.new(:assistant, ThinkingDouble.new(text, nil))
    end

    test "strips reasoning_content but keeps reasoning for a known-strict gateway (Cerebras)" do
      payload = provider_for("https://api.cerebras.ai/v1")
                .send(:format_thinking, assistant_message)

      assert_equal "chain of thought", payload[:reasoning]
      assert_not payload.key?(:reasoning_content),
                 "reasoning_content must be stripped for gateways that reject it (Cerebras)"
    end

    test "keeps reasoning_content for DeepSeek, which requires it in thinking mode" do
      payload = provider_for("https://api.deepseek.com/v1")
                .send(:format_thinking, assistant_message)

      assert_equal "chain of thought", payload[:reasoning_content],
                   "DeepSeek 400s when the replayed reasoning_content is missing; it must be preserved"
    end

    test "keeps both keys for hosted OpenAI (no gateway configured)" do
      payload = provider_for(nil).send(:format_thinking, assistant_message)

      assert_equal "chain of thought", payload[:reasoning]
      assert_equal "chain of thought", payload[:reasoning_content]
    end

    test "keeps both keys when the base is the official OpenAI endpoint" do
      payload = provider_for("https://api.openai.com/v1")
                .send(:format_thinking, assistant_message)

      assert payload.key?(:reasoning_content),
             "hosted OpenAI requests must stay byte-identical"
    end

    test "keeps reasoning_content for an unknown/unlisted custom gateway" do
      payload = provider_for("https://api.some-other-llm.example/v1")
                .send(:format_thinking, assistant_message)

      assert payload.key?(:reasoning_content),
             "the key is only dropped for denylisted hosts; unknown gateways are left untouched"
    end

    test "keeps reasoning_content for a deceptive host that merely contains the Cerebras string" do
      payload = provider_for("https://api.cerebras.ai.evil.example/v1")
                .send(:format_thinking, assistant_message)

      assert payload.key?(:reasoning_content),
             "denylist match is on the exact parsed host, not a substring"
    end

    test "no-op for messages without a replayed thinking block" do
      payload = provider_for("https://api.cerebras.ai/v1")
                .send(:format_thinking, MessageDouble.new(:user, nil))

      assert_equal({}, payload)
    end
  end
end
