# frozen_string_literal: true

require "test_helper"

class RubyLlmInteractionLoggerTest < ActiveSupport::TestCase
  test "serializes message values without traversing request context or credentials" do
    context = RubyLLM.context { |config| config.openai_api_key = "private-key" }
    chat = context.chat(model: "gpt-4.1", provider: :openai, protocol: :chat_completions, assume_model_exists: true)
    chat.add_message(role: :user, content: "Hello", config: context.config)
    chat.add_message(role: :assistant, content: "World", config: context.config, input_tokens: 10)
    log = Collavre::RubyLlmInteractionLogger.log(vendor: "openai", model: "gpt-4.1", messages: chat.messages)

    assert_equal [ "Hello", "World" ], log.log.fetch("messages").map { |message| message.fetch("content") }
    refute_includes log.log.to_json, "private-key"
    refute_includes log.log.to_json, "openai_api_key"
  end

  test "serializes registered tools as schema values" do
    tool = Tools::MetaToolService.ruby_llm_tools([ "meta_tool" ]).first.new
    log = Collavre::RubyLlmInteractionLogger.log(vendor: "openai", model: "gpt-4.1", messages: [], tools: [ [ :meta_tool, tool ] ])
    schema = log.log.fetch("tools").first.last

    assert_equal "meta_tool", schema.fetch("name")
    assert_equal "object", schema.fetch("parameters").fetch("type")
    assert schema.fetch("parameters").fetch("properties").key?("action")
  end
end
