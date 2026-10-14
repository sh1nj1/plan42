# frozen_string_literal: true

require "test_helper"
require "ostruct"

module Collavre
  class AiClientDecisionTest < ActiveSupport::TestCase
    QUESTIONS = { status: { type: :choice, instructions: "Is the work done?",
                            options: { DONE: "Executed", CONTINUE: "Work remains" } } }.freeze

    setup do
      @agent = users(:ai_bot)
      @client = AiClient.new(vendor: "google", model: "test", system_prompt: "Evaluate strictly",
        llm_api_key: "test", context: { user: @agent })
    end

    def response(choice = "DONE", reason = "")
      OpenStruct.new(content: { "answers" => { "status" => { "choice" => choice } }, "reason" => reason },
        tokens: RubyLLM::Tokens.new(input: 11, output: 3))
    end

    def fake_chat(result = response)
      chat = Object.new
      chat.define_singleton_method(:messages) { [] }
      chat.define_singleton_method(:tools) { [] }
      chat.define_singleton_method(:with_schema) { |schema| @schema = schema }
      chat.define_singleton_method(:after_message) { |&callback| @callback = callback }
      chat.define_singleton_method(:ask) do |_prompt|
        @callback&.call(result)
        result
      end
      chat
    end

    test "chat decisions return validated choice and reason with usage" do
      chat = fake_chat(response("CONTINUE", "PR missing"))
      @client.stub(:build_conversation, chat) do
        assert_difference -> { LlmUsage.count }, 1 do
          result = @client.judge("Task", questions: QUESTIONS)
          assert_equal "CONTINUE", result.dig("answers", "status", "choice")
          assert_equal "PR missing", result["reason"]
          assert_equal "chat", result["source"]
        end
      end
      assert_equal 11, @client.last_input_tokens
      assert_equal 3, @client.last_output_tokens
    end

    test "invalid or empty chat decisions never become completion" do
      [ "", "DONE", { "answers" => { "status" => { "choice" => "INVALID" } } } ].each do |content|
        chat = fake_chat(OpenStruct.new(content: content))
        @client.stub(:build_conversation, chat) do
          assert_raises(JSON::ParserError, ArgumentError) { @client.judge("Task", questions: QUESTIONS) }
        end
      end
    end

    test "native decisions use typesafe context and track usage" do
      client = AiClient.new(vendor: "typesafe", model: "jev-latest", system_prompt: "Strict",
        llm_api_key: "secret", gateway_url: "https://judge.example", context: { user: @agent })
      config = RubyLLM.config.dup
      answer = OpenStruct.new(to_h: { type: :choice, choice: "DONE" })
      judgment = OpenStruct.new(answers: { status: answer }, tokens: RubyLLM::Tokens.new(input: 8, output: 1))
      ctx = Object.new
      ctx.define_singleton_method(:judge) do |input, **options|
        raise "Missing instructions" unless input[:instructions] == "Strict"
        raise "Wrong provider" unless options[:provider] == :typesafe && options[:assume_model_exists]
        judgment
      end
      factory = ->(&block) { block.call(config); ctx }
      RubyLLM.stub(:context, factory) do
        assert_difference -> { LlmUsage.count }, 1 do
          assert_equal "DONE", client.judge("Task", questions: QUESTIONS).dig("answers", "status", "choice")
        end
      end
      assert_equal "secret", config.typesafe_api_key
      assert_equal "https://judge.example", config.typesafe_api_base
      assert_equal 8, client.last_input_tokens
    end

    test "ordinary OpenAI models judge through structured chat without calling Decisions" do
      %w[gpt-4 gpt-4o gpt-5 unknown-model].each do |model|
        client = AiClient.new(vendor: "openai", model: model, system_prompt: nil)
        client.stub(:native_decision, ->(*) { flunk "Chat model must not call Decisions" }) do
          client.stub(:build_conversation, fake_chat(response("CONTINUE", "Work remains"))) do
            result = client.judge("Task", questions: QUESTIONS)
            assert_equal "chat", result["source"]
            assert_equal "CONTINUE", result.dig("answers", "status", "choice")
          end
        end
      end
    end

    test "OpenAI judgment models use the native decision path" do
      client = AiClient.new(vendor: "openai", model: "gpt-6-luna", system_prompt: nil)
      client.stub(:native_decision, ->(*) { "native verdict" }) do
        client.stub(:chat_decision, ->(*) { flunk "Judgment model must use Decisions" }) do
          assert_equal "native verdict", client.judge("Task", questions: QUESTIONS)
        end
      end
    end

    test "native judgment support is model-specific for OpenAI" do
      assert AiClient.supports?(" OpenAI ", :judge, model: "gpt-6-luna")
      %w[gpt-4 gpt-4o gpt-5 unknown-model].each do |model|
        assert_not AiClient.supports?("openai", :judge, model: model)
        assert AiClient.supports?("openai", :chat, model: model)
      end
      assert_not AiClient.supports?("openai", :judge, model: "")
      assert AiClient.supports?("typesafe", :judge, model: "jev-latest")
    end

    test "missing decisions endpoint falls back to chat but authentication failure does not" do
      client = AiClient.new(vendor: "openai", model: "gpt-6-luna", system_prompt: nil)
      [ 404, 405, 501, 400, 401, 429, 500 ].each do |status|
        failure = RubyLLM::Error.new("Unavailable", response: OpenStruct.new(status: status))
        native = ->(*) { raise failure }
        client.stub(:native_decision, native) do
          client.stub(:chat_decision, ->(*) { "chat fallback" }) do
            if [ 404, 405, 501 ].include?(status)
              assert_equal "chat fallback", client.judge("Task", questions: QUESTIONS)
            else
              assert_raises(RubyLLM::Error) { client.judge("Task", questions: QUESTIONS) }
            end
          end
        end
      end
    end

    test "schema rejection retries with JSON prompt and no schema" do
      first = fake_chat
      first.define_singleton_method(:ask) { |*| raise RubyLLM::BadRequestError, "response_format unsupported" }
      chats = [ first, fake_chat ]
      @client.stub(:build_conversation, -> { chats.shift }) do
        assert_equal "DONE", @client.judge("Task", questions: QUESTIONS).dig("answers", "status", "choice")
      end
      assert_empty chats
    end

    test "native failures propagate while recording failed usage" do
      client = AiClient.new(vendor: "typesafe", model: "jev-latest", system_prompt: nil,
        context: { user: @agent })
      ctx = Object.new
      ctx.define_singleton_method(:judge) { |*, **| raise RubyLLM::UnauthorizedError, "Invalid key" }
      client.stub(:build_llm_context, ctx) do
        assert_difference -> { LlmUsage.count }, 1 do
          assert_raises(RubyLLM::UnauthorizedError) { client.judge("Task", questions: QUESTIONS) }
        end
      end
    end

    test "anthropic context preserves per-agent key" do
      client = AiClient.new(vendor: "anthropic", model: "test", system_prompt: nil, llm_api_key: "agent-key")
      config = RubyLLM.config.dup
      RubyLLM.stub(:context, ->(&block) { block.call(config); Object.new }) do
        client.send(:build_llm_context)
      end
      assert_equal "agent-key", config.anthropic_api_key
    end

    test "registered chat adapter is preserved for JSON decisions" do
      client = AiClient.new(vendor: "external-adapter", model: "test", system_prompt: nil)
      adapter = ->(messages, &block) {
        assert_includes messages.first[:text], "response_schema"
        block.call(response("CONTINUE", "Adapter work remains").content.to_json)
        nil
      }
      client.stub(:build_conversation, -> { flunk "Adapter must not use a built-in provider" }) do
        client.stub(:chat, adapter) do
          result = client.judge("Task", questions: QUESTIONS)
          assert_equal "CONTINUE", result.dig("answers", "status", "choice")
          assert_equal "Adapter work remains", result["reason"]
        end
      end
    end

    test "native-only vendor never falls back to chat on endpoint failure" do
      client = AiClient.new(vendor: "typesafe", model: "jev-latest", system_prompt: nil)
      error = RubyLLM::Error.new("Unavailable", response: OpenStruct.new(status: 404))
      client.stub(:native_decision, ->(*) { raise error }) do
        assert_raises(RubyLLM::Error) { client.judge("Task", questions: QUESTIONS) }
      end
    end

    test "JSON code fence is parsed and malformed answers are rejected" do
      content = "```json\n#{response.content.to_json}\n```"
      @client.stub(:build_conversation, fake_chat(OpenStruct.new(content: content))) do
        assert_equal "DONE", @client.judge("Task", questions: QUESTIONS).dig("answers", "status", "choice")
      end
      @client.stub(:build_conversation, fake_chat(OpenStruct.new(content: { "answers" => {} }))) do
        assert_raises(KeyError) { @client.judge("Task", questions: QUESTIONS) }
      end
    end

    test "chat endpoint failures do not repeat a chat decision" do
      calls = 0
      chat = fake_chat
      chat.define_singleton_method(:ask) do |*|
        calls += 1
        raise RubyLLM::Error.new("Not found", response: OpenStruct.new(status: 404))
      end
      @client.stub(:build_conversation, chat) do
        assert_raises(RubyLLM::Error) { @client.judge("Task", questions: QUESTIONS) }
      end
      assert_equal 1, calls
    end

    test "non-schema bad requests do not retry" do
      chat = fake_chat
      chat.define_singleton_method(:ask) { |*| raise RubyLLM::BadRequestError, "Invalid API parameter" }
      @client.stub(:build_conversation, chat) do
        assert_raises(RubyLLM::BadRequestError) { @client.judge("Task", questions: QUESTIONS) }
      end
    end

    test "vendors declare capabilities with chat as extension default" do
      assert AiClient.supports?("openai", :judge)
      assert AiClient.supports?("typesafe", :judge)
      assert_not AiClient.supports?("typesafe", :chat)
      assert AiClient.supports?("custom", :chat)
      assert_not AiClient.supports?("google", :judge)
      assert_includes AiClient.vendor_options, [ "TypesafeAI", "typesafe" ]
    end

    test "extension capabilities can be declared explicitly" do
      previous = AiClient.vendor_capabilities.dup
      AiClient.register_vendor_capabilities("TEST-EXTENSION", capabilities: [ :judge ])
      assert AiClient.supports?("test-extension", :judge)
      assert_not AiClient.supports?("test-extension", :chat)
    ensure
      AiClient.instance_variable_set(:@vendor_capabilities, previous)
    end

    test "decision questions validate probability and score bounds" do
      definitions = DecisionQuestions.new(p: { type: :probability }, s: { type: :score, levels: %w[low high] })
      assert definitions.schema
      result = definitions.normalize({ answers: { p: { probability: 0.5 }, s: { score: 1 } } }, source: "chat")
      assert_equal 0.5, result.dig("answers", "p", "probability")
      assert_raises(ArgumentError) do
        definitions.normalize({ answers: { p: { probability: 2 }, s: { score: 1 } } }, source: "chat")
      end
      assert_raises(ArgumentError) { DecisionQuestions.new({}) }
      assert_raises(ArgumentError) { DecisionQuestions.new(q: { type: :text }) }
    end
  end
end
