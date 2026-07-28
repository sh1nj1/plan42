# frozen_string_literal: true

require "test_helper"
require "ostruct"

class AiClientTest < ActiveSupport::TestCase
  class FakeConversation
    attr_reader :messages_added, :instructions_set, :headers_set

    def initialize(response_content: "final response")
      @response_content = response_content
      @messages_added = []
      @instructions_set = nil
      @headers_set = nil
    end

    def with_instructions(instructions)
      @instructions_set = instructions
    end

    def with_headers(**headers)
      @headers_set = headers
      self
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

  test "build_conversation supplies a placeholder key for a keyless local gateway" do
    # Local OpenAI-compatible gateways (Ollama / LM Studio) need no real key, but
    # RubyLLM raises ConfigurationError if openai_api_key is blank. We inject a
    # placeholder so the request proceeds; otherwise the call silently returns nil.
    client = AiClient.new(
      vendor: "openai",
      model: "gemma3",
      system_prompt: nil,
      llm_api_key: nil,
      gateway_url: "http://localhost:11434/v1"
    )

    fake_chat = FakeConversation.new
    mock_context = Object.new
    mock_context.define_singleton_method(:chat) { |**| fake_chat }

    mock_config = Minitest::Mock.new
    mock_config.expect(:openai_api_key=, nil, [ "local-gateway" ])
    mock_config.expect(:openai_api_base=, nil, [ "http://localhost:11434/v1" ])

    context_stub = proc do |&block|
      block.call(mock_config) if block
      mock_context
    end

    Collavre::IntegrationSettings.stub(:fetch, nil) do
      RubyLLM.stub(:context, context_stub) do
        client.send(:build_conversation)
      end
    end

    assert mock_config.verify
  end

  test "build_conversation sets X-Session-Id header from creative and topic" do
    creative = OpenStruct.new(id: 42)
    comment = OpenStruct.new(topic_id: 7)

    fake_chat = build_conversation_with_context(creative: creative, comment: comment)

    assert_equal({ "X-Session-Id" => "creative_42_topic_7" }, fake_chat.headers_set)
  end

  test "build_conversation sets X-Session-Id header from top-level topic_id context" do
    creative = OpenStruct.new(id: 42)

    fake_chat = build_conversation_with_context(creative: creative, topic_id: 7)

    assert_equal({ "X-Session-Id" => "creative_42_topic_7" }, fake_chat.headers_set)
  end

  test "build_conversation omits X-Session-Id when topic is missing" do
    creative = OpenStruct.new(id: 42)
    comment = OpenStruct.new(topic_id: nil)

    fake_chat = build_conversation_with_context(creative: creative, comment: comment)

    assert_nil fake_chat.headers_set
  end

  test "build_conversation omits X-Session-Id when context is empty" do
    fake_chat = build_conversation_with_context

    assert_nil fake_chat.headers_set
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

  private

  def build_conversation_with_context(context_hash = {})
    client = AiClient.new(vendor: "google", model: "gemini-pro",
                          system_prompt: nil, llm_api_key: "api-key",
                          context: context_hash.presence || {})
    fake_chat = FakeConversation.new
    mock_context = Object.new
    mock_context.define_singleton_method(:chat) { |**_kwargs| fake_chat }
    context_stub = proc do |&block|
      block.call(OpenStruct.new) if block
      mock_context
    end
    RubyLLM.stub(:context, context_stub) { client.send(:build_conversation) }
    fake_chat
  end

  public

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

  test "does not log raw error message to app log when log_interactions is false" do
    # Inline typo correction passes log_interactions: false because it runs on the
    # user's *unsubmitted* draft. An LLM error whose message echoes that draft must
    # not leak to Rails.logger — only the error class may be logged.
    draft = "my-secret-unsubmitted-draft-xyzzy"
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      raise StandardError, "Gemini 400: bad request for input '#{draft}'"
    end

    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key",
      log_interactions: false
    )

    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| logged << msg.to_s }
    fake_logger.define_singleton_method(:warn) { |msg| logged << msg.to_s }
    fake_logger.define_singleton_method(:debug) { |*_| }

    Rails.stub(:logger, fake_logger) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: draft } ] } ])
      end
    end

    joined = logged.join("\n")
    assert_not_includes joined, draft, "draft text leaked to app log on error path"
    assert(logged.any? { |m| m.include?("StandardError") }, "error class should still be logged")
  end

  test "surfaces provider error response body when RubyLLM masks the reason" do
    # RubyLLM raises BadRequestError with the generic "Invalid request" fallback
    # when the provider's 400 body isn't in OpenAI's {error:{message}} shape (e.g.
    # OpenAI-compatible gateways like Cerebras). The real reason lives only on the
    # raw HTTP response; the client must surface its status + body to the app log.
    raw_body = { "detail" => "tools[0].function.parameters: invalid schema" }.to_json
    response = OpenStruct.new(status: 400, body: raw_body)
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      raise RubyLLM::BadRequestError.new(response, "Invalid request - please check your input")
    end

    client = AiClient.new(
      vendor: "openai", model: "gpt-oss-120b", system_prompt: "system", llm_api_key: "api-key"
    )

    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| logged << msg.to_s }
    fake_logger.define_singleton_method(:debug) { |*_| }
    # Debug logging (development) surfaces the full body; production is asserted below.
    fake_logger.define_singleton_method(:debug?) { true }

    Rails.stub(:logger, fake_logger) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: "hi" } ] } ])
      end
    end

    joined = logged.join("\n")
    assert_includes joined, "status=400"
    assert_includes joined, "tools[0].function.parameters: invalid schema"
  end

  test "suppresses provider error body at INFO but records status and size" do
    # A 400 body can echo the offending prompt/tool arguments. At INFO (production)
    # the raw body must not reach centralized app logs; only the status and body
    # size are recorded so the rejection is still traceable without leaking content.
    secret = "user-prompt-should-not-leak-to-prod-logs"
    raw_body = { "detail" => secret }.to_json
    response = OpenStruct.new(status: 400, body: raw_body)
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      raise RubyLLM::BadRequestError.new(response, "Invalid request - please check your input")
    end

    client = AiClient.new(
      vendor: "openai", model: "gpt-oss-120b", system_prompt: "system", llm_api_key: "api-key"
    )

    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| logged << msg.to_s }
    fake_logger.define_singleton_method(:debug) { |*_| }
    fake_logger.define_singleton_method(:debug?) { false }

    Rails.stub(:logger, fake_logger) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: "hi" } ] } ])
      end
    end

    joined = logged.join("\n")
    assert_includes joined, "status=400", "status must still be recorded at INFO"
    assert_includes joined, "body_size=#{raw_body.bytesize}B", "body size must be recorded at INFO"
    assert_not_includes joined, secret, "raw provider body leaked to app log at INFO"
  end

  test "reinterprets ASCII-8BIT provider error body as UTF-8 so non-ASCII is readable" do
    # Provider error bodies arrive tagged ASCII-8BIT even when the bytes are valid
    # UTF-8; without reinterpretation the transcode into the UTF-8 log fails (the
    # original "log writing failed" symptom) and Korean/other text is unreadable.
    binary_body = "잘못된 요청".dup.force_encoding("ASCII-8BIT")
    response = OpenStruct.new(status: 400, body: binary_body)
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      raise RubyLLM::BadRequestError.new(response, "Invalid request - please check your input")
    end

    client = AiClient.new(
      vendor: "openai", model: "gpt-oss-120b", system_prompt: "system", llm_api_key: "api-key"
    )

    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| logged << msg.to_s }
    fake_logger.define_singleton_method(:debug) { |*_| }
    fake_logger.define_singleton_method(:debug?) { true }

    Rails.stub(:logger, fake_logger) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: "hi" } ] } ])
      end
    end

    assert(logged.any? { |m| m.include?("잘못된 요청") }, "Korean error body should be logged readably")
  end

  test "does not surface provider error response body when log_interactions is false" do
    # A 400 validation body can echo the offending input, so the response-body log
    # is gated by log_interactions just like the error-message log.
    secret = "unsubmitted-draft-qwerty"
    response = OpenStruct.new(status: 400, body: { "input" => secret }.to_json)
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      raise RubyLLM::BadRequestError.new(response, "Invalid request - please check your input")
    end

    client = AiClient.new(
      vendor: "openai", model: "gpt-oss-120b", system_prompt: "system",
      llm_api_key: "api-key", log_interactions: false
    )

    logged = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| logged << msg.to_s }
    fake_logger.define_singleton_method(:debug) { |*_| }

    Rails.stub(:logger, fake_logger) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: secret } ] } ])
      end
    end

    assert_not_includes logged.join("\n"), secret, "response body leaked despite log_interactions:false"
  end

  test "response-body logging never breaks the error path when the response is malformed" do
    # log_error_response is a diagnostic helper on the failure path, so a malformed
    # response object must never turn a provider error into a crash. A response that
    # raises while its body is read exercises the defensive rescue: the AI error is
    # still surfaced to the caller and only a debug breadcrumb is left behind.
    response = Object.new
    response.define_singleton_method(:status) { 400 }
    response.define_singleton_method(:body) { raise "cannot read body" }
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      raise RubyLLM::BadRequestError.new(response, "Invalid request - please check your input")
    end

    client = AiClient.new(
      vendor: "openai", model: "gpt-oss-120b", system_prompt: "system", llm_api_key: "api-key"
    )

    errors = []
    debugs = []
    fake_logger = Object.new
    fake_logger.define_singleton_method(:error) { |msg| errors << msg.to_s }
    fake_logger.define_singleton_method(:debug) { |*args| debugs << args.join }
    fake_logger.define_singleton_method(:debug?) { true }

    yielded = +""
    Rails.stub(:logger, fake_logger) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: "hi" } ] } ]) { |delta| yielded << delta }
      end
    end

    assert_includes yielded, "AI Error", "caller must still receive the error despite the malformed response"
    assert(debugs.any? { |m| m.include?("log_error_response failed") },
           "the defensive rescue should leave a debug breadcrumb")
  end

  test "yields whitespace-only deltas instead of dropping them" do
    # Providers routinely emit a paragraph break as a chunk of its own. "\n\n" is
    # blank? == true, so skipping blank deltas deletes it — and since the delta is
    # then never yielded either, AiAgentService (which persists only what it was
    # yielded, via ResponseStreamer) writes the reply to the database with its
    # paragraphs glued together. Empty deltas — role-only and tool-call chunks
    # carry no content — must still be skipped.
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&block|
      [ "First.", "\n\n", "Second.", "" ].each { |d| block.call(OpenStruct.new(content: d)) }
      block.call(OpenStruct.new(content: nil))
      OpenStruct.new(content: nil)
    end

    client = AiClient.new(
      vendor: "google",
      model: "gemini-pro",
      system_prompt: "system",
      llm_api_key: "api-key"
    )

    yielded = []
    result = client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |delta| yielded << delta }
    end

    assert_equal [ "First.", "\n\n", "Second." ], yielded
    assert_equal "First.\n\nSecond.", result
  end

  # #chat swallows a provider error: it streams "⚠️ AI Error" to the user and
  # returns nil, which an ordinary empty answer also returns. Orchestration::
  # DeliveryRecord needs the two apart — a turn that handed the provider
  # nothing delivered nothing, and the dispatches it discarded on the strength
  # of "the agent has read that comment" have to come back.
  test "records a handoff failure when the request errors before any content" do
    conversation = FakeConversation.new
    def conversation.complete
      raise StandardError, "connection refused"
    end

    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    result = client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
    end

    assert_nil result, "premise: the caught error is indistinguishable from an empty answer by return value"
    assert_predicate client, :last_handoff_failed?
  end

  # Control, and the boundary: an error *after* deltas have streamed is not a
  # failed handoff. The provider had the payload and answered part of it, which
  # the product surfaces as a truncated reply — the agent did read the comments
  # that turn swallowed.
  test "does not record a handoff failure when the error came after content streamed" do
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&block|
      block.call(OpenStruct.new(content: "half an answer"))
      raise StandardError, "stream closed"
    end

    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    yielded = +""
    client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |delta| yielded << delta }
    end

    assert_includes yielded, "half an answer", "premise: the provider did answer, partially"
    assert_not client.last_handoff_failed?
  end

  # Control against the flag latching: an ordinary chat leaves it false, and so
  # does an empty-but-successful one, which returns nil for a different reason.
  test "does not record a handoff failure on a chat that reached the provider" do
    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    client.stub(:build_conversation, FakeConversation.new) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
    end
    assert_not client.last_handoff_failed?

    empty = FakeConversation.new
    empty.define_singleton_method(:complete) { |&_block| OpenStruct.new(content: "") }
    client.stub(:build_conversation, empty) do
      assert_nil client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
    end
    assert_not client.last_handoff_failed?,
               "an empty answer is an answer; the provider had the payload"
  end

  # The other half of the same question, asked positively. #last_handoff_failed?
  # is only ever set from a rescue, so it cannot answer for a chat that raised
  # past it — which is what a user pressing Stop mid-answer does. What the
  # cancelled turn needs to know is whether the provider got the payload.
  test "records the handoff once content has streamed" do
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&block|
      block.call(OpenStruct.new(content: "half an answer"))
      raise Collavre::CancelledError
    end

    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    assert_raises(Collavre::CancelledError) do
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |_delta| nil }
      end
    end

    assert_predicate client, :handed_off?
  end

  # Deltas are not the only way an answer arrives: a provider that returns its
  # whole reply at once yields nothing at all, and that turn handed over just as
  # much. The delta branch alone would read it as never having reached anybody.
  test "records the handoff for an answer that arrived without deltas" do
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&_block|
      OpenStruct.new(content: "the whole answer")
    end

    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    result = client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
    end

    assert_equal "the whole answer", result, "premise: nothing streamed, and yet it answered"
    assert_predicate client, :handed_off?
  end

  # Control: nothing streamed means nothing was handed over — the same boundary
  # #last_handoff_failed? draws — and the answer belongs to this chat alone, not
  # to the one before it.
  test "records no handoff for a chat that streamed nothing" do
    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    client.stub(:build_conversation, FakeConversation.new) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
    end
    assert_predicate client, :handed_off?, "premise: the chat before it did stream"

    silent = FakeConversation.new
    silent.define_singleton_method(:complete) do |&_block|
      raise Collavre::CancelledError
    end
    assert_raises(Collavre::CancelledError) do
      client.stub(:build_conversation, silent) do
        client.chat([ { role: "user", parts: [ { text: "hello" } ] } ])
      end
    end

    assert_not client.handed_off?
  end

  # A delta of exactly "\n\n" is content — the delta branch says so in as many
  # words, and skips only truly *empty* chunks for that reason. The rescue below
  # it classified with `blank?`, which is true of that same delta, so a stream
  # broken after a paragraph break recorded the handoff *and* its failure. Task#
  # ended_undelivered? reads the failure first, so every comment that turn
  # swallowed is dispatched again although the provider had them.
  test "does not record a handoff failure when the error came after a whitespace-only delta" do
    conversation = FakeConversation.new
    conversation.define_singleton_method(:complete) do |&block|
      block.call(OpenStruct.new(content: "\n\n"))
      raise StandardError, "stream closed"
    end

    client = AiClient.new(
      vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
    )

    yielded = []
    client.stub(:build_conversation, conversation) do
      client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |delta| yielded << delta }
    end

    assert_equal "\n\n", yielded.first, "premise: the provider streamed, and the delta reached the caller"
    assert_predicate client, :handed_off?, "premise: the payload got there"
    assert_not client.last_handoff_failed?
  end

  # The invariant Task#ended_undelivered? is written on: the two records are one
  # boundary asked twice, so no ending can carry both. It reads the failure
  # first precisely because it cannot ask which of two contradictory records is
  # the true one — that has to be impossible here rather than resolved there.
  test "records the handoff and its failure as one boundary asked two ways" do
    [ [ "nothing", nil ], [ "a paragraph break", "\n\n" ], [ "an answer", "half an answer" ] ].each do |what, streamed|
      conversation = FakeConversation.new
      conversation.define_singleton_method(:complete) do |&block|
        block.call(OpenStruct.new(content: streamed)) if streamed
        raise StandardError, "stream closed"
      end

      client = AiClient.new(
        vendor: "google", model: "gemini-pro", system_prompt: "system", llm_api_key: "api-key"
      )
      client.stub(:build_conversation, conversation) do
        client.chat([ { role: "user", parts: [ { text: "hello" } ] } ]) { |_delta| nil }
      end

      assert_equal !client.handed_off?, client.last_handoff_failed?,
                   "a stream that broke after #{what} must answer the same question the same way"
    end
  end
end
