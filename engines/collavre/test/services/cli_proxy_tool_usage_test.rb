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

  def client_with(chunks, vendor: "cli_proxy", log: true, ask_events: [], reasoning_effort: nil)
    client = Collavre::AiClient.new(vendor: vendor, model: "paperclip/claude_local", system_prompt: nil,
                                    log_interactions: log, context: { reasoning_effort: reasoning_effort })
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
    assert_equal [ [ "Bash", true ], [ "mcp__collavre__creative_retrieval_service", true ], [ "Read", false ] ],
                 usages.map { |usage| [ usage.tool_name, usage.succeeded ] }
    assert usages.all? { |usage| usage.source == "cli_proxy" }
    assert_equal [ Collavre::LlmUsage.last.execution_id ], usages.map(&:execution_id).uniq
    assert_kind_of Integer, usages.first.duration_ms
    assert_nil usages.last.duration_ms, "a result whose call never streamed has no duration"
  end

  test "cli_proxy sends the run's reasoning effort with the cli events request" do
    client, conversation = client_with(run_chunks, reasoning_effort: "high")

    client.chat([ { role: "user", text: "hi" } ])

    assert_equal({ x_cli_events: "reasoning", reasoning_effort: "high" }, conversation.params)
  end

  test "compression and merge clients send the configured agent effort" do
    agent = users(:ai_bot)
    agent.assign_attributes(llm_vendor: "cli_proxy", llm_model: "paperclip/claude_local", reasoning_effort: "high")
    arguments = [ agent, creatives(:tshirt), nil, users(:one) ]
    clients = [
      Collavre::CompressJob.new.send(:build_client, *arguments, "Summarize"),
      Collavre::MergeCommentsJob.new.send(:build_client, *arguments)
    ]
    clients.each do |client|
      conversation = Conversation.new([])
      client.define_singleton_method(:build_conversation) { |_tools| conversation }
      client.chat([])
      assert_equal({ x_cli_events: "reasoning", reasoning_effort: "high" }, conversation.params)
    end
  end

  test "client effort prefers a valid override and filters defaults for its actual model" do
    agent = users(:ai_bot)
    agent.reasoning_effort = "max"
    [ [ "high", "high" ], [ nil, "max" ], [ "invalid", "max" ] ].each do |override, expected|
      client, conversation = client_with([], reasoning_effort: override)
      client.send(:context)[:user] = agent
      client.chat([])
      assert_equal expected, conversation.params[:reasoning_effort]
    end

    client, conversation = client_with([])
    client.send(:context)[:user] = agent
    client.instance_variable_set(:@model, "paperclip/codex_local")
    client.chat([])
    assert_equal({ x_cli_events: "reasoning" }, conversation.params)
  end

  %w[claude_local codex_local].each do |adapter|
    test "#{adapter} applies chat then agent defaults and otherwise omits effort for local settings" do
      agent = users(:ai_bot)
      [ [ "low", "high", "low" ], [ "", "high", "high" ], [ nil, nil, nil ] ].each do |chat_effort, default, expected|
        agent.reasoning_effort = default
        agent.codex_fast_mode = true
        client, conversation = client_with([], reasoning_effort: chat_effort)
        client.send(:context)[:user] = agent
        client.instance_variable_set(:@model, "paperclip/#{adapter}")
        client.chat([])
        logged = Collavre::ActivityLog.order(:id).last.log.fetch("run_options")
        assert_equal expected, logged["reasoning_effort"] if expected
        assert_nil logged["reasoning_effort"] unless expected
        assert_equal expected ? "request" : "local_default", logged["reasoning_source"]
        assert_equal adapter == "codex_local", logged["codex_fast_mode_configured"]
        client.ask("Summary")
        assert_equal logged, Collavre::ActivityLog.order(:id).last.log.fetch("run_options")
        if expected
          assert_equal expected, conversation.params[:reasoning_effort]
        else
          assert_not conversation.params.key?(:reasoning_effort)
        end
      end
    end
  end

  test "other vendors neither request nor record cli events" do
    client, conversation = client_with(run_chunks, vendor: "openai")
    seen = []
    client.on_cli_tool_event { |cli_event| seen << cli_event }

    assert_equal "Answer", client.chat([])

    assert_nil conversation.params
    assert_not Collavre::ActivityLog.order(:id).last.log.key?("run_options")
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

  test "Collavre MCP tools are recorded under any server alias" do
    recorder = Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-alias")
    names = %w[mcp__collavre__topic_list mcp__workspace__topic_list workspace.topic_list]
    names.each_with_index { |name, index| recorder.observe(event("a#{index}", "result", name, ok: false)) }

    assert_equal names, Collavre::ToolUsage.order(:id).pluck(:tool_name)
  end

  def mcp_row(tool_name, workspace_id:, at:, arguments: nil, succeeded: true)
    Collavre::ToolUsage.create!(event_key: SecureRandom.uuid, execution_id: SecureRandom.uuid, source: "mcp",
      tool_name: tool_name, requester_kind: "unknown", occurred_at: at, agent_workspace_id: workspace_id,
      arguments_digest: Collavre::ToolUsage.arguments_digest(arguments), succeeded: succeeded)
  end

  test "among identical /mcp calls a proxy result replaces one with the same outcome" do
    arguments = { id: 1 }
    succeeded_row = mcp_row("creatives_update", workspace_id: 7, at: 30.seconds.ago, arguments: arguments)
    failed_row = mcp_row("creatives_update", workspace_id: 7, at: 20.seconds.ago, arguments: arguments, succeeded: false)
    recorder = Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-b",
      agent_workspace: Struct.new(:id).new(7), since: 1.minute.ago)

    recorder.observe(event("b", "call", "mcp__workspace__creatives_update", input: { "id" => 1 }))
    recorder.observe(event("b", "result", "mcp__workspace__creatives_update", ok: false))

    assert_equal [ succeeded_row.id ], Collavre::ToolUsage.where(source: "mcp").pluck(:id)
    refute Collavre::ToolUsage.exists?(failed_row.id)

    recorder.observe(event("c", "call", "mcp__workspace__creatives_update", input: { "id" => 1 }))
    recorder.observe(event("c", "result", "mcp__workspace__creatives_update", ok: false))
    assert_empty Collavre::ToolUsage.where(source: "mcp"), "with no same-outcome row, the oldest identical row is replaced"
  end

  test "a proxy result replaces the /mcp row with its own arguments, not another run's" do
    run_a = mcp_row("creatives_update", workspace_id: 7, at: 30.seconds.ago, arguments: { id: 1, title: "A" })
    run_b = mcp_row("creatives_update", workspace_id: 7, at: 20.seconds.ago, arguments: { title: "B", id: 2 })
    recorder = Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-b",
      agent_workspace: Struct.new(:id).new(7), since: 1.minute.ago)

    recorder.observe(event("b", "call", "mcp__workspace__creatives_update", input: { "id" => 2, "title" => "B" }))
    recorder.observe(event("b", "result", "mcp__workspace__creatives_update", ok: true))
    assert_equal [ run_a.id ], Collavre::ToolUsage.where(source: "mcp").pluck(:id)
    refute Collavre::ToolUsage.exists?(run_b.id)

    recorder.observe(event("c", "call", "mcp__workspace__creatives_update", input: { "id" => 3 }))
    recorder.observe(event("c", "result", "mcp__workspace__creatives_update", ok: false))
    assert_equal [ run_a.id ], Collavre::ToolUsage.where(source: "mcp").pluck(:id), "a call that never reached /mcp takes no row"

    recorder.observe(event("d", "call", "workspace.creatives_update", input: "{\"id\":4… [truncated 9000 bytes]"))
    recorder.observe(event("d", "result", "workspace.creatives_update", ok: true))
    assert_empty Collavre::ToolUsage.where(source: "mcp"), "a clipped input falls back to the oldest row"
    assert_equal 3, Collavre::ToolUsage.where(source: "cli_proxy").count
  end

  test "a proxy result replaces the matching /mcp row of its workspace and run, once" do
    since = 1.minute.ago
    stale = mcp_row("topic_list", workspace_id: 7, at: 2.minutes.ago)
    other_workspace = mcp_row("topic_list", workspace_id: 8, at: Time.current)
    first = mcp_row("topic_list", workspace_id: 7, at: 30.seconds.ago)
    second = mcp_row("topic_list", workspace_id: 7, at: 20.seconds.ago)
    other_tool = mcp_row("cron_list", workspace_id: 7, at: 10.seconds.ago)
    recorder = Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-mcp",
      agent_workspace: Struct.new(:id).new(7), since: since)

    recorder.observe(event("a", "result", "mcp__workspace__topic_list", ok: true))
    recorder.observe(event("a", "result", "mcp__workspace__topic_list", ok: true))
    recorder.observe(event("b", "result", "Bash", ok: true))

    remaining = Collavre::ToolUsage.where(source: "mcp").order(:id).pluck(:id)
    assert_equal [ stale, other_workspace, second, other_tool ].map(&:id), remaining
    refute Collavre::ToolUsage.exists?(first.id)
    assert_equal %w[mcp__workspace__topic_list Bash], Collavre::ToolUsage.where(source: "cli_proxy").order(:id).pluck(:tool_name)

    recorder.observe(event("c", "result", "workspace.topic_list", ok: true))
    refute Collavre::ToolUsage.exists?(second.id)
  end

  test "a /mcp row without a proxy result, or a recorder without a workspace, is kept" do
    row = mcp_row("topic_list", workspace_id: 7, at: Time.current)
    Collavre::ToolUsage::CliProxyRecorder.new(context: {}, execution_id: "exec-none")
      .observe(event("a", "result", "mcp__workspace__topic_list"))

    assert Collavre::ToolUsage.exists?(row.id)
  end

  test "a cli_proxy run reconciles against its own workspace from when usage tracking started" do
    client, = client_with([ stream_chunk(event("m1", "result", "mcp__workspace__topic_list", ok: true)), stream_chunk(content: "ok") ])
    client.instance_variable_set(:@cli_proxy_identity, { workspace: Struct.new(:id).new(9) })
    stale = mcp_row("topic_list", workspace_id: 9, at: 1.hour.ago)
    client.define_singleton_method(:start_usage_tracking) do |**options|
      super(**options)
      Collavre::ToolUsage.create!(event_key: SecureRandom.uuid, execution_id: SecureRandom.uuid, source: "mcp",
        tool_name: "topic_list", requester_kind: "unknown", occurred_at: Time.current, agent_workspace_id: 9)
    end

    client.chat([])

    assert_equal [ stale.id ], Collavre::ToolUsage.where(source: "mcp").pluck(:id)
    assert_equal 1, Collavre::ToolUsage.where(source: "cli_proxy").count
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
