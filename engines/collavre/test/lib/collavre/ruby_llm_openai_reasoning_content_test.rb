# frozen_string_literal: true

require "test_helper"

module Collavre
  # Guards the initializer patch that stops RubyLLM's OpenAI provider from
  # sending the non-schema `reasoning_content` field to strict OpenAI-compatible
  # gateways (e.g. Cerebras), which reject it with a 400 on the tool-result
  # follow-up request.
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

    test "strips reasoning_content but keeps reasoning for a custom gateway" do
      payload = provider_for("https://api.cerebras.ai/v1")
                .send(:format_thinking, assistant_message)

      assert_equal "chain of thought", payload[:reasoning]
      assert_not payload.key?(:reasoning_content),
                 "reasoning_content must be stripped for custom OpenAI-compatible gateways"
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

    test "no-op for messages without a replayed thinking block" do
      payload = provider_for("https://api.cerebras.ai/v1")
                .send(:format_thinking, MessageDouble.new(:user, nil))

      assert_equal({}, payload)
    end
  end
end
