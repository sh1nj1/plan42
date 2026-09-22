# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class CliProxyToolUsageTest < ActiveSupport::TestCase
  def event(id, phase, name, **extra)
    { "id" => id, "phase" => phase, "name" => name }.merge(extra.stringify_keys)
  end

  def stream_chunk(*events, content: nil)
    delta = { "reasoning_content" => "trace\n", "x_cli_events" => events }
    delta["content"] = content if content
    RubyLLM::Providers::OpenAI.allocate.send(:build_chunk, "choices" => [ { "delta" => delta } ])
  end

  # Streams the given chunks and answers "Answer"; #ask answers without
  # streaming, carrying its events on the final message like the proxy does.
  class Conversation
    attr_reader :params, :messages

    def initialize(chunks, ask_events: [])
      @chunks = chunks
      @ask_events = ask_events
      @callbacks = []
      @messages = []
    end

    def with_params(**params)
      @params = params
      self
    end

    def after_message(&callback)
      @callbacks << callback
    end

    def complete
      @chunks.each { |chunk| yield chunk }
      finish(RubyLLM::Message.new(role: :assistant, content: "Answer", input_tokens: 3, output_tokens: 1))
    end

    def ask(_prompt)
      message = RubyLLM::Message.new(role: :assistant, content: "Summary", input_tokens: 3, output_tokens: 1)
      message.cli_events = @ask_events
      finish(message)
    end

    def with_tools(*, **)
    end

    def tools
      []
    end

    def with_headers(**)
    end

    def add_message(**)
    end

    private

    def finish(message)
      @messages << message
      @callbacks.each { |callback| callback.call(message) }
      message
    end
  end

  def client_with(chunks, vendor: "cli_proxy", log: true, ask_events: [])
    client = Collavre::AiClient.new(vendor: vendor, model: "paperclip/claude_local", system_prompt: nil, log_interactions: log)
    conversation = Conversation.new(chunks, ask_events: ask_events)
    client.define_singleton_method(:build_conversation) { |_tools| conversation }
    [ client, conversation ]
  end

  def run_chunks
    [
      stream_chunk(event("t1", "call", "Bash", input: { "command" => "ls" })),
      stream_chunk(event("t1", "result", "Bash", output: "a.txt", ok: true)),
      stream_chunk(event("m1", "call", "mcp__collavre__creative_retrieval_service"),
                   event("m1", "result", "mcp__collavre__creative_retrieval_service", ok: true)),
      stream_chunk(event("s1", "result", "Read", ok: false, parentId: "task-1")),
      stream_chunk(content: "Answer")
    ]
  end

  test "cli_proxy asks for x_cli_events and records each tool result under the run's execution" do
    client, conversation = client_with(run_chunks)
    seen = []
    assert_same client, client.on_cli_tool_event { |cli_event| seen << cli_event.values_at("id", "phase") }

    assert_equal "Answer", client.chat([ { role: "user", text: "hi" } ])

    assert_equal({ x_cli_events: "reasoning" }, conversation.params)
    assert_equal [ %w[t1 call], %w[t1 result], %w[m1 call], %w[m1 result], %w[s1 result] ], seen
    usages = Collavre::ToolUsage.order(:id)
    assert_equal [ [ "Bash", true ], [ "Read", false ] ], usages.map { |usage| [ usage.tool_name, usage.succeeded ] }
    assert usages.all? { |usage| usage.source == "cli_proxy" }
    assert_equal [ Collavre::LlmUsage.last.execution_id ], usages.map(&:execution_id).uniq
    assert_kind_of Integer, usages.first.duration_ms
    assert_nil usages.last.duration_ms, "a result whose call never streamed has no duration"
  end

  test "other vendors neither request nor record cli events" do
    client, conversation = client_with(run_chunks, vendor: "openai")
    seen = []
    client.on_cli_tool_event { |cli_event| seen << cli_event }

    assert_equal "Answer", client.chat([])

    assert_nil conversation.params
    assert_empty seen
    assert_equal 0, Collavre::ToolUsage.count
  end

  test "non-streaming ask records the events of its own execution without duration" do
    client, = client_with([], ask_events: [ event("c1", "call", "command_execution"),
                                            event("c1", "result", "command_execution", exitCode: 2) ])
    client.chat([])

    assert_equal "Summary", client.ask("Summarize")

    usage = Collavre::ToolUsage.sole
    assert_equal [ "command_execution", false, nil ], [ usage.tool_name, usage.succeeded, usage.duration_ms ]
    assert_equal Collavre::LlmUsage.order(:id).last.execution_id, usage.execution_id
  end

  test "listener and recording failures never break the chat" do
    client, = client_with(run_chunks)
    client.on_cli_tool_event { |_cli_event| raise "UI down" }
    Collavre::ToolUsage.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, "Unavailable" }) do
      assert_equal "Answer", client.chat([])
    end
    assert_equal 0, Collavre::ToolUsage.count
  end

  test "a cancelling listener stops the chat" do
    client, = client_with(run_chunks)
    client.on_cli_tool_event { |_cli_event| raise Collavre::CancelledError, "Stopped" }

    assert_raises(Collavre::CancelledError) { client.chat([]) }
    assert client.handed_off?, "a chunk reaching the listener is already a handoff"
  end

  test "a tool result is recorded even when its listener cancels" do
    client, = client_with(run_chunks)
    client.on_cli_tool_event { |cli_event| raise Collavre::CancelledError, "Stopped" if cli_event["phase"] == "result" }

    assert_raises(Collavre::CancelledError) { client.chat([]) }
    usage = Collavre::ToolUsage.sole
    assert_equal [ "Bash", true ], [ usage.tool_name, usage.succeeded ]
  end

  test "private chats notify listeners but record no usage" do
    client, = client_with(run_chunks, log: false)
    seen = []
    client.on_cli_tool_event.on_cli_tool_event { |cli_event| seen << cli_event }

    assert_equal "Answer", client.chat([])

    assert_equal 5, seen.size
    assert_equal 0, Collavre::ToolUsage.count
  end

  test "recorder is idempotent per call id, ignores unanswered calls and falls back to exitCode" do
    recorder = Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-1")
    recorder.observe(event("a", "call", "Bash"))
    recorder.observe(event("a", "result", "Bash", exitCode: 0))
    recorder.observe(event("a", "result", "Bash", exitCode: 0))
    recorder.observe(event("b", "call", "Edit"))
    recorder.observe(event("c", "result", "Bash", exitCode: 1))
    recorder.observe({ "phase" => "result", "name" => "" })
    recorder.observe(event("d", "progress", "Bash"))

    rows = Collavre::ToolUsage.order(:id).map { |usage| [ usage.tool_name, usage.succeeded, usage.event_key ] }
    assert_equal [ [ "Bash", true, "exec-1:cli_proxy:a" ], [ "Bash", false, "exec-1:cli_proxy:c" ],
                   [ "tool", true, "exec-1:cli_proxy:seq-3" ] ], rows
    assert_equal "exec-1", recorder.execution_id
  end

  test "recorder measures call to result time only for timed events" do
    recorder = Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-2")
    clock = [ 10.0, 10.25 ]
    recorder.stub(:monotonic_now, -> { clock.shift }) do
      recorder.observe(event("a", "call", "Bash"))
      recorder.observe(event("a", "result", "Bash"))
    end
    recorder.observe(event("b", "call", "Bash"), timed: false)
    recorder.observe(event("b", "result", "Bash"), timed: false)

    assert_equal [ 250, nil ], Collavre::ToolUsage.order(:id).pluck(:duration_ms)
  end

  test "Collavre MCP tools are left to the mcp source" do
    skipped = %w[mcp__collavre__creative_retrieval_service mcp__plugin_collavre_collavre__reply
                 collavre.creative_update_service Collavre-Dev.topic_list]
    kept = %w[Bash Edit command_execution web_search mcp__github__get_pr github.get_pr mcp__notion__search_collavre]

    skipped.each { |name| assert Collavre::ToolUsage::CliProxyRecorder.collavre_mcp_tool?(name), name }
    kept.each { |name| assert_not Collavre::ToolUsage::CliProxyRecorder.collavre_mcp_tool?(name), name }
    assert_not Collavre::ToolUsage::CliProxyRecorder.collavre_mcp_tool?(nil)
  end

  test "the real OpenAI provider sends x_cli_events to cli_proxy only" do
    WebMock.disable_net_connect!
    owner = users(:one)
    gateway = Collavre::AgentGateway.create!(owner: owner, name: "Events proxy", base_url: "https://proxy.example.com",
                                             admin_key: "admin", completion_key: "completion-secret")
    agent = Collavre::User.create!(name: "Events agent", email: "events-agent@ai.local", password: SecureRandom.hex(24),
                                   system_prompt: "Help", llm_vendor: "cli_proxy", llm_model: "paperclip/claude_local",
                                   created_by_id: owner.id, agent_gateway: gateway)
    sse = [
      { "choices" => [ { "index" => 0, "delta" => { "role" => "assistant", "reasoning_content" => "Bash(ls)\n",
                                                    "x_cli_events" => [ event("t1", "call", "Bash") ] } } ] },
      { "choices" => [ { "index" => 0, "delta" => { "reasoning_content" => "ok\n",
                                                    "x_cli_events" => [ event("t1", "result", "Bash", ok: true) ] } } ] },
      { "choices" => [ { "index" => 0, "delta" => { "content" => "Done" } } ] }
    ].map { |data| "data: #{data.to_json}\n\n" }.join + "data: [DONE]\n\n"
    proxy = stub_request(:post, "https://proxy.example.com/v1/chat/completions")
      .with { |request| JSON.parse(request.body)["x_cli_events"] == "reasoning" }
      .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })
    gateway_request = stub_request(:post, "https://gateway.example.com/v1/chat/completions")
      .with { |request| !JSON.parse(request.body).key?("x_cli_events") }
      .to_return(status: 200, body: sse, headers: { "Content-Type" => "text/event-stream" })

    proxy_client = Collavre::AiClient.new(vendor: "cli_proxy", model: agent.llm_model, system_prompt: nil,
                                          context: { user: agent })
    assert_equal "Done", proxy_client.chat([ { role: "user", text: "hi" } ]) { |_delta| }
    gateway_client = Collavre::AiClient.new(vendor: "openai", model: "gpt-test", system_prompt: nil,
                                            gateway_url: "https://gateway.example.com/v1", llm_api_key: "key")
    assert_equal "Done", gateway_client.chat([ { role: "user", text: "hi" } ]) { |_delta| }

    assert_requested proxy
    assert_requested gateway_request
    assert_equal [ [ "Bash", "cli_proxy", agent.id ] ], Collavre::ToolUsage.pluck(:tool_name, :source, :agent_id)
  ensure
    WebMock.allow_net_connect!
  end
end
