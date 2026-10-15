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

    test "native decisions preserve weighted fractional scores" do
      levels = %w[low medium high]
      answer = RubyLLM::Score.new(score: 1.37, levels: levels,
        probabilities: { 0 => 0.1, 1 => 0.43, 2 => 0.47 }, confidence: 0.9)
      judgment = OpenStruct.new(answers: { rating: answer }, tokens: RubyLLM::Tokens.new(input: 8, output: 1))
      context = Object.new
      context.define_singleton_method(:judge) { |*, **| judgment }
      client = AiClient.new(vendor: "typesafe", model: "jev-latest", system_prompt: nil)
      client.stub(:build_llm_context, context) do
        result = client.judge("Task", questions: { rating: { type: :score, levels: levels } })
        assert_equal 1.37, result.dig("answers", "rating", "score")
        assert_equal "judge", result["source"]
      end
    end

    test "native weighted scores still require finite values within bounds" do
      definitions = DecisionQuestions.new(rating: { type: :score, levels: %w[low high] })
      [ -0.1, 1.1, Float::NAN, Float::INFINITY, "0.5", nil ].each do |score|
        assert_raises(ArgumentError) do
          definitions.normalize({ answers: { rating: { score: score } } }, source: "judge")
        end
      end
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

    test "masked schema rejection retries using raw JSON response details" do
      [ { "detail" => "response_format unsupported" }.to_json,
        { "errors" => [ { "message" => "invalid structured output schema" } ] }.to_json,
        { "detail" => "schema unsupported" } ].each do |body|
        first = fake_chat
        raw_response = OpenStruct.new(status: 400, body: body)
        first.define_singleton_method(:ask) do |*|
          raise RubyLLM::BadRequestError.new("Invalid request - please check your input", response: raw_response)
        end
        second = fake_chat
        second.define_singleton_method(:with_schema) { |*| flunk "fallback must not request a schema" }
        chats = [ first, second ]
        @client.stub(:build_conversation, -> { chats.shift }) do
          assert_equal "DONE", @client.judge("Task", questions: QUESTIONS).dig("answers", "status", "choice")
        end
        assert_empty chats
      end
    end

    test "HTTP 422 schema rejections retry but unrelated errors propagate" do
      [ [ "response_format unsupported", true ], [ "Invalid API parameter", false ] ].each do |detail, retries|
        failure = RubyLLM::Error.new("Invalid request - please check your input",
          response: OpenStruct.new(status: 422, body: { detail: detail }.to_json))
        first = fake_chat
        first.define_singleton_method(:ask) { |*| raise failure }
        second = fake_chat
        second.define_singleton_method(:with_schema) { |*| flunk "fallback must not request a schema" }
        chats = [ first, second ]
        @client.stub(:build_conversation, -> { chats.shift }) do
          if retries
            assert_equal "DONE", @client.judge("Task", questions: QUESTIONS).dig("answers", "status", "choice")
          else
            assert_same failure, assert_raises(RubyLLM::Error) { @client.judge("Task", questions: QUESTIONS) }
          end
        end
        assert_equal(retries ? [] : [ second ], chats)
      end
    end

    test "masked unrelated or malformed error bodies do not retry" do
      [ '{"detail":"Invalid API parameter"}', '<html>schema gateway error</html>', nil ].each do |body|
        chat = fake_chat
        raw_response = OpenStruct.new(status: 400, body: body)
        chat.define_singleton_method(:ask) do |*|
          raise RubyLLM::BadRequestError.new("Invalid request - please check your input", response: raw_response)
        end
        calls = 0
        @client.stub(:build_conversation, -> { calls += 1; chat }) do
          assert_raises(RubyLLM::BadRequestError) { @client.judge("Task", questions: QUESTIONS) }
        end
        assert_equal 1, calls
      end
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
      assert_not AiClient.supports?("test-extension", :judge)
      assert_not AiClient.supports?("test-extension", :chat)
    ensure
      AiClient.instance_variable_set(:@vendor_capabilities, previous)
    end

    test "unmapped judgment vendors with chat support use their chat adapter" do
      capabilities = AiClient.vendor_capabilities.merge("acme" => %i[chat judge])
      client = AiClient.new(vendor: "acme", model: "test", system_prompt: "Evaluate", llm_api_key: "test", context: { user: @agent })
      AiClient.stub(:vendor_capabilities, capabilities) do
        assert_not AiClient.supports?("acme", :judge)
        client.stub(:chat, ->(*) { response.content.to_json }) do
          result = client.judge("Task", questions: QUESTIONS)
          assert_equal "DONE", result.dig("answers", "status", "choice")
          assert_equal "chat", result["source"]
        end
      end
    end

    test "unmapped judgment-only vendors never call chat transport" do
      capabilities = AiClient.vendor_capabilities.merge("acme" => [ :judge ])
      client = AiClient.new(vendor: "acme", model: "test", system_prompt: nil)
      AiClient.stub(:vendor_capabilities, capabilities) do
        client.stub(:chat, ->(*) { flunk "Unsupported vendor reached chat transport" }) do
          assert_raises(ArgumentError) { client.judge("Task", questions: QUESTIONS) }
        end
      end
    end

    test "choice questions need at least two options before adapter selection" do
      %w[google typesafe].each do |vendor|
        client = AiClient.new(vendor: vendor, model: "test", system_prompt: nil)
        client.stub(:native_decision, ->(*) { flunk "Invalid choice reached native adapter" }) do
          client.stub(:chat_decision, ->(*) { flunk "Invalid choice reached chat adapter" }) do
            [ {}, { only: "Only option" } ].each do |options|
              assert_raises(ArgumentError) do
                client.judge("Task", questions: { status: { type: :choice, options: options } })
              end
            end
          end
        end
      end
    end

    test "invalid choice descriptions fail before either decision adapter is called" do
      %w[google typesafe].each do |vendor|
        client = AiClient.new(vendor: vendor, model: "test", system_prompt: nil)
        client.stub(:native_decision, ->(*) { flunk "Invalid description reached native adapter" }) do
          client.stub(:chat_decision, ->(*) { flunk "Invalid description reached chat adapter" }) do
            [ 1, 0.5, true, false ].each do |description|
              assert_raises(ArgumentError) do
                client.judge("Task", questions: { status: { type: :choice,
                  options: { DONE: description, CONTINUE: "Keep working" } } })
              end
            end
          end
        end
      end
    end

    test "invalid question metadata fails before either decision adapter is called" do
      invalid = [
        { type: :probability, instructions: 123 },
        { type: :score, levels: [ "Low", "High" ], instructions: false },
        { type: :choice, options: { "" => "Empty", DONE: "Done" } },
        { type: :choice, options: [ "Done", "Continue" ] }
      ]
      %w[google typesafe].each do |vendor|
        client = AiClient.new(vendor: vendor, model: "test", system_prompt: nil)
        client.stub(:native_decision, ->(*) { flunk "Invalid metadata reached native adapter" }) do
          client.stub(:chat_decision, ->(*) { flunk "Invalid metadata reached chat adapter" }) do
            invalid.each do |definition|
              assert_raises(ArgumentError) { client.judge("Task", questions: { result: definition }) }
            end
          end
        end
      end
    end

    test "question instructions accept native description types" do
      [ nil, "", "Judge carefully", { "rubric" => "Done" }, [ "Done" ] ].each do |instructions|
        definitions = DecisionQuestions.new(done: { type: :probability, instructions: instructions })
        assert_equal({ "type" => :probability, "instructions" => instructions }, definitions.definitions["done"])
        assert definitions.schema
      end
      assert DecisionQuestions.new(status: { type: :choice, options: { " " => nil, DONE: "Done" } }).schema
    end

    test "choice descriptions accept the native description types" do
      [ "Done", { text: "Done" }, [ "Done" ], nil ].each do |description|
        definitions = DecisionQuestions.new(status: { type: :choice,
          options: { DONE: description, CONTINUE: "Keep working" } })
        assert_equal %w[DONE CONTINUE],
          definitions.schema.dig(:properties, :answers, :properties, "status", :properties, "choice", :enum)
      end
    end

    test "invalid score scales fail before either decision adapter is called" do
      [ "google", "typesafe" ].each do |vendor|
        client = AiClient.new(vendor: vendor, model: "test", system_prompt: nil)
        client.stub(:native_decision, ->(*) { flunk "Invalid scale reached native adapter" }) do
          client.stub(:chat_decision, ->(*) { flunk "Invalid scale reached chat adapter" }) do
            [ [], [ "only" ], Array.new(11, "level"), "ok", nil, { low: "low", high: "high" },
              [ "low", 1 ], [ "low", false ] ].each do |levels|
              assert_raises(ArgumentError) do
                client.judge("Task", questions: { rating: { type: :score, levels: levels } })
              end
            end
          end
        end
      end
    end

    test "score levels accept native structured descriptions" do
      [ [ { max: 10 }, { min: 11 } ], [ [ "low" ], [ "high" ] ], [ nil, nil ], [ "", "  " ] ].each do |levels|
        definitions = DecisionQuestions.new(rating: { type: :score, levels: levels })
        assert_equal 1, definitions.schema.dig(:properties, :answers, :properties, "rating", :properties, "score", :maximum)
        assert_equal levels.map { |level| level.is_a?(Hash) ? level.stringify_keys : level },
          definitions.definitions.fetch("rating").fetch("levels")
      end
    end

    test "invalid probability criteria fail before either decision adapter is called" do
      %w[google typesafe].each do |vendor|
        client = AiClient.new(vendor: vendor, model: "test", system_prompt: nil)
        client.stub(:native_decision, ->(*) { flunk "Invalid criteria reached native adapter" }) do
          client.stub(:chat_decision, ->(*) { flunk "Invalid criteria reached chat adapter" }) do
            [ "yes", [], false, 1, { yes: 1, no: 0 }, { yes: false }, { maybe: "Maybe" },
              { yes: "Yes", true: "Also yes" }, { no: "No", false: "Also no" } ].each do |criteria|
              assert_raises(ArgumentError) do
                client.judge("Task", questions: { done: { type: :probability, criteria: criteria } })
              end
            end
          end
        end
      end
    end

    test "probability criteria accept optional native descriptions and outcome aliases" do
      [ nil, {}, { yes: "Yes", no: "No" }, { true => { max: 10 }, false => [ "No" ] },
        { yes: nil }, { no: "" }, { true: "Yes", no: "No" } ].each do |criteria|
        definitions = DecisionQuestions.new(done: { type: :probability, criteria: criteria })
        assert_equal "number", definitions.schema.dig(:properties, :answers, :properties, "done", :properties, "probability", :type)
      end
    end

    test "score scales accept both native contract boundaries" do
      [ 2, 10 ].each do |count|
        definitions = DecisionQuestions.new(rating: { type: :score, levels: Array.new(count, "level") })
        assert_equal count - 1, definitions.schema.dig(:properties, :answers, :properties, "rating", :properties, "score", :maximum)
        [ 0, count - 1 ].each do |score|
          result = definitions.normalize({ answers: { rating: { score: score } } }, source: "chat")
          assert_equal score, result.dig("answers", "rating", "score")
        end
      end
    end

    test "chat score answers require integer level indices" do
      definitions = DecisionQuestions.new(rating: { type: :score, levels: %w[low high] })
      schema = definitions.schema.dig(:properties, :answers, :properties, "rating", :properties, "score")
      assert_equal "integer", schema[:type]

      %w[chat adapter].each do |source|
        [ 0.5, 1.0, -1, 2, "1", nil ].each do |score|
          assert_raises(ArgumentError) do
            definitions.normalize({ answers: { rating: { score: score } } }, source: source)
          end
        end
        [ 0, 1 ].each do |score|
          result = definitions.normalize({ answers: { rating: { score: score } } }, source: source)
          assert_equal score, result.dig("answers", "rating", "score")
        end
      end
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
