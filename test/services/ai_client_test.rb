# frozen_string_literal: true

require "test_helper"
require "ostruct"

class AiClientTest < ActiveSupport::TestCase
  class FakeConversation
    attr_reader :messages_added, :instructions_set

    def initialize(response_content: "final response")
      @response_content = response_content
      @messages_added = []
      @instructions_set = nil
    end

    def with_instructions(instructions)
      @instructions_set = instructions
    end

    def with_tool(*)
    end

    def on_tool_call(&block)
    end

    def add_message(role:, content:)
      @messages_added << { "role" => role.to_s, "parts" => [ { "text" => content } ] }
    end

    def messages
      @messages_added
    end

    def tools
      []
    end

    def complete
      yield OpenStruct.new(content: "chunk") if block_given?
      OpenStruct.new(content: @response_content, input_tokens: 10, output_tokens: 20)
    end
  end

  # ... existing tests ...

  test "build_conversation does not set nil system prompt" do
    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: nil,
      llm_api_key: "api-key"
    )

    fake_chat = FakeConversation.new

    mock_context = Object.new
    mock_context.define_singleton_method(:chat) do |model:|
      fake_chat
    end

    mock_config = Minitest::Mock.new
    mock_config.expect(:gemini_api_key=, nil, [ "api-key" ])

    context_stub = proc do |&block|
      block.call(mock_config) if block
      mock_context
    end

    RubyLLM.stub(:context, context_stub) do
      client.send(:build_conversation)
    end

    assert_nil fake_chat.instructions_set
    mock_config.verify
  end

  test "build_conversation sets system prompt when present" do
    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "Be helpful",
      llm_api_key: "api-key"
    )

    fake_chat = FakeConversation.new

    mock_context = Object.new
    mock_context.define_singleton_method(:chat) do |model:|
      fake_chat
    end

    mock_config = Minitest::Mock.new
    mock_config.expect(:gemini_api_key=, nil, [ "api-key" ])

    context_stub = proc do |&block|
      block.call(mock_config) if block
      mock_context
    end

    RubyLLM.stub(:context, context_stub) do
      client.send(:build_conversation)
    end

    assert_equal "Be helpful", fake_chat.instructions_set
    mock_config.verify
  end

  test "persists prompt and response to ruby llm logs" do
    ActivityLog.delete_all
    conversation = FakeConversation.new(response_content: "full response")

    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |_delta| }
    end

    log_entry = ActivityLog.last
    assert_equal 1, ActivityLog.count
    assert_equal "llm_query", log_entry.activity

    log_data = log_entry.log
    assert_equal "google", log_data["vendor"]
    assert_equal "gemini-pro", log_data["model"]
    assert_equal conversation.messages_added, log_data["messages"]
    assert_equal [], log_data["tools"]
    assert_equal "full response", log_data["response_content"]
    assert_nil log_data["error_message"]
    assert_equal 10, log_data["input_tokens"]
    assert_equal 20, log_data["output_tokens"]
  end

  test "logs error details when chat fails" do
    ActivityLog.delete_all
    conversation = FakeConversation.new
    def conversation.complete
      raise StandardError, "boom"
    end

    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    result = client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
    end

    assert_nil result

    log_entry = ActivityLog.last
    assert_equal 1, ActivityLog.count
    assert_equal "boom", log_entry.log["error_message"]
    assert_nil log_entry.log["response_content"]
  end
end
