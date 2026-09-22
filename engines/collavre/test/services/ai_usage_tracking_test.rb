# frozen_string_literal: true

require "test_helper"
require "ostruct"

class AiUsageTrackingTest < ActiveSupport::TestCase
  class Conversation
    attr_reader :messages
    attr_accessor :failure

    def initialize
      @messages = []
    end

    def after_message(&callback)
      @callback = callback
    end

    def complete
      2.times do
        message = RubyLLM::Message.new(role: :assistant, content: "Answer", input_tokens: 10,
                                      output_tokens: 2, cached_tokens: 30)
        yield message
        raise failure if failure

        @messages << message
        @callback.call(message)
      end
      @messages.last
    end

    def ask(_prompt)
      complete { |_message| }
    end

    def with_tools(*)
    end

    def tools
      []
    end

    def with_headers(**)
    end
  end

  def client_and_conversation(log: true)
    client = Collavre::AiClient.new(vendor: "openai", model: "test", system_prompt: nil, log_interactions: log)
    conversation = Conversation.new
    client.define_singleton_method(:build_conversation) do |_tools|
      conversation
    end
    [ client, conversation ]
  end

  test "chat records tool iterations once and summary ask records another execution" do
    client, = client_and_conversation
    assert_equal "Answer", client.chat([])
    assert_equal 2, Collavre::LlmUsage.count
    assert_equal 80, Collavre::LlmUsage.sum(:input_tokens)
    assert Collavre::LlmUsage.all.all?(&:activity_log_id)
    assert_equal "Answer", client.ask("Summarize")
    assert_equal 4, Collavre::LlmUsage.count
    assert_equal 2, Collavre::LlmUsage.distinct.count(:execution_id)
  end

  test "cancellation preserves partial usage and no logging mode remains private" do
    client, conversation = client_and_conversation
    conversation.failure = Collavre::CancelledError.new("Stopped")
    assert_raises(Collavre::CancelledError) { client.chat([]) }
    assert_equal 40, Collavre::LlmUsage.last.input_tokens
    client, = client_and_conversation(log: false)
    assert_no_difference "Collavre::LlmUsage.count" do
      client.chat([])
      client.ask("summary")
    end
  end

  test "provider failure and recording failure do not replace the response" do
    client, conversation = client_and_conversation
    conversation.failure = RuntimeError.new("Provider error")
    assert_nil client.chat([])
    assert_equal 1, Collavre::LlmUsage.count
    client, = client_and_conversation
    Collavre::LlmUsage.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "Unavailable" }) do
      assert_equal "Answer", client.chat([])
    end
  end

  test "accounting setup failures do not prevent provider calls" do
    client, = client_and_conversation
    Collavre::LlmUsage::Attribution.stub(:snapshot, ->(*) { raise ActiveRecord::StatementInvalid, "Unavailable" }) do
      assert_equal "Answer", client.chat([])
    end
    assert_equal 0, Collavre::LlmUsage.count
  end

  test "link failures do not replace a completed response" do
    client, = client_and_conversation
    failing = Object.new
    failing.define_singleton_method(:record) { |*| }
    failing.define_singleton_method(:observe) { |*| }
    failing.define_singleton_method(:finish) { |*| }
    failing.define_singleton_method(:attach) { |*| raise ActiveRecord::StatementInvalid, "Unavailable" }
    Collavre::LlmUsage::Recorder.stub(:new, failing) do
      assert_equal "Answer", client.chat([])
    end
  end

  test "OpenAI usage normalization restores inclusive prompt tokens" do
    usage = { "prompt_tokens" => 100, "completion_tokens" => 5,
              "prompt_tokens_details" => { "cached_tokens" => 70, "cache_write_tokens" => 10 } }
    message = RubyLLM::Providers::OpenAI.allocate.send(:build_chunk, "usage" => usage)
    normalized = Collavre::LlmUsage::TokenNormalizer.normalize(Collavre::LlmUsage::TokenNormalizer.parts(message), usage, vendor: "openai")
    assert_equal 100, normalized[:input_tokens]
    assert_equal 70, normalized[:cache_read_tokens]
    assert_equal 10, normalized[:cache_write_tokens]
    message = RubyLLM::Providers::OpenAI.allocate.send(:build_chunk, "usage" => { "prompt_tokens" => 100 })
    normalized = Collavre::LlmUsage::TokenNormalizer.normalize(Collavre::LlmUsage::TokenNormalizer.parts(message), {}, vendor: "cli_proxy")
    assert_nil normalized[:cache_write_tokens]
    assert_nil normalized[:cache_read_tokens]
    assert_equal 100, normalized[:input_tokens]
  end
end
