# frozen_string_literal: true

require "test_helper"
require "ostruct"

class AiClientTest < ActiveSupport::TestCase
  class FakeConversation
    attr_reader :messages_added

    def initialize(response_content: "final response")
      @response_content = response_content
      @messages_added = []
    end

    def with_instructions(*)
    end

    def with_tool(*)
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
