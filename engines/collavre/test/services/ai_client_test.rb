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

    def with_tools(*tools, replace: false, choice: nil, calls: nil)
      self
    end

    def on_tool_call(&block)
    end

    def ask(prompt)
      OpenStruct.new(content: "Summary: #{prompt.truncate(50)}")
    end

    def add_message(role:, content:)
      if content.is_a?(RubyLLM::Content)
        @messages_added << { "role" => role.to_s, "content" => content }
      else
        @messages_added << { "role" => role.to_s, "parts" => [ { "text" => content } ] }
      end
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
    mock_context.define_singleton_method(:chat) do |**kwargs|
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
    mock_context.define_singleton_method(:chat) do |**kwargs|
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

  test "add_messages handles image parts with Content" do
    conversation = FakeConversation.new

    client = Collavre::AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    # Create a temporary file to simulate an image source
    tempfile = Tempfile.new([ "test", ".png" ])
    tempfile.write("\x89PNG\r\n\x1a\n") # PNG header
    tempfile.rewind

    messages = [
      { role: "user", parts: [ { text: "What is this?" }, { image: tempfile.path } ] }
    ]

    client.send(:add_messages, conversation, messages)

    assert_equal 1, conversation.messages_added.size
    msg = conversation.messages_added.first
    assert_equal "user", msg["role"]
    assert_instance_of RubyLLM::Content, msg["content"]
    assert_equal "What is this?", msg["content"].text
    assert_equal 1, msg["content"].attachments.size
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "add_messages passes ActiveStorage blob as RubyLLM attachment" do
    conversation = FakeConversation.new

    client = Collavre::AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    # Create a real ActiveStorage blob
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("\x89PNG\r\n\x1a\n" + "\x00" * 100),
      filename: "test_image.png",
      content_type: "image/png"
    )

    messages = [
      { role: "user", parts: [ { text: "Describe this image" }, { image: blob } ] }
    ]

    client.send(:add_messages, conversation, messages)

    assert_equal 1, conversation.messages_added.size
    msg = conversation.messages_added.first
    assert_equal "user", msg["role"]

    content = msg["content"]
    assert_instance_of RubyLLM::Content, content
    assert_equal "Describe this image", content.text
    assert_equal 1, content.attachments.size

    attachment = content.attachments.first
    assert_instance_of RubyLLM::Attachment, attachment
    assert attachment.active_storage?, "Attachment should recognize ActiveStorage blob"
    assert_equal "image/png", attachment.mime_type
    assert attachment.image?, "Attachment should be recognized as image"

    # Verify the attachment can actually download content
    downloaded = attachment.content
    assert downloaded.present?, "Attachment content should be downloadable"
    assert downloaded.start_with?("\x89PNG".b), "Downloaded content should be PNG data"
  ensure
    blob&.purge
  end

  test "add_messages works with text-only parts unchanged" do
    conversation = FakeConversation.new

    client = Collavre::AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    messages = [
      { role: "user", parts: [ { text: "hello" } ] }
    ]

    client.send(:add_messages, conversation, messages)

    assert_equal 1, conversation.messages_added.size
    msg = conversation.messages_added.first
    assert_equal "user", msg["role"]
    assert_equal [ { "text" => "hello" } ], msg["parts"]
  end

  test "ask uses existing conversation for follow-up" do
    conversation = FakeConversation.new

    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    # Simulate a chat that sets up @conversation
    client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |_| }
    end

    # Now ask a follow-up using the same conversation
    result = client.ask("Summarize what this tool does")
    assert_includes result, "Summary:"
    assert_includes result, "Summarize what this tool does"
  end

  test "ask returns nil when no conversation exists" do
    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    result = client.ask("test")
    assert_nil result
  end

  test "ask returns nil on error" do
    conversation = FakeConversation.new
    def conversation.ask(_prompt)
      raise StandardError, "API error"
    end

    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |_| }
    end

    result = client.ask("test")
    assert_nil result
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
    assert_equal "[StandardError] boom", log_entry.log["error_message"]
    assert_nil log_entry.log["response_content"]
  end
end
