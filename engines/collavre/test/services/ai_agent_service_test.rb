require "test_helper"

class AiAgentServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @creative = creatives(:tshirt)
    @agent = users(:ai_bot)

    # Ensure agent has routing expression
    @agent.update!(routing_expression: "true")

    @comment = @creative.comments.create!(content: "Hello AI", user: @user)

    @task = Task.create!(
      name: "Test Task",
      status: "running",
      trigger_event_name: "comment_created",
      trigger_event_payload: {
        "comment" => { "id" => @comment.id, "content" => @comment.content },
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => @comment.topic_id }
      },
      agent: @agent,
      topic_id: @comment.topic_id
    )
  end

  test "creates placeholder and streams content into it" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Chunk 1 "
      yield "Chunk 2"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    initial_comment_count = @creative.comments.count

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # One new comment: the placeholder that was updated with final content
    assert_equal initial_comment_count + 1, @creative.comments.count

    reply = @creative.comments.where(user: @agent).order(:created_at).last
    assert_equal "Chunk 1 Chunk 2", reply.content
    assert_equal @creative.main_topic.id, reply.topic_id

    # Verify actions were logged
    assert @task.task_actions.exists?(action_type: "start")
    assert @task.task_actions.exists?(action_type: "completion")
    assert @task.task_actions.exists?(action_type: "reply_created")
  end

  test "broadcasts thinking and idle agent status" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Response"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    broadcasts = []
    creative_id = @creative.effective_origin.id

    ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    presence_broadcasts = broadcasts.select { |b| b[:channel] == "comments_presence:#{creative_id}" }
    agent_statuses = presence_broadcasts.select { |b| b[:data][:agent_status].present? }

    statuses = agent_statuses.map { |b| b[:data][:agent_status][:status] }
    assert_includes statuses, "thinking"
    assert_includes statuses, "idle"
    assert agent_statuses.all? { |broadcast| broadcast[:data][:agent_status][:topic_id] == @comment.topic_id }

    thinking_idx = statuses.index("thinking")
    idle_idx = statuses.rindex("idle")
    assert thinking_idx < idle_idx
  end

  test "reassociates activity logs from trigger comment to reply comment" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "AI Response"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    activity_log = ActivityLog.create!(
      activity: "llm_query",
      creative: @creative,
      user: @agent,
      comment: @comment,
      log: { model: "test", response_content: "AI Response" }
    )

    assert_equal @comment.id, activity_log.comment_id

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    reply = @creative.comments.where(user: @agent).order(:created_at).last
    activity_log.reload

    assert_equal reply.id, activity_log.comment_id
    assert_not_equal @comment.id, activity_log.comment_id
    assert_equal 0, ActivityLog.where(comment: @comment, user: @agent).count
    assert_equal 1, reply.activity_logs.count
  end

  test "destroys placeholder when response is empty" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      # No yield - empty response
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    initial_comment_count = @creative.comments.count

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # Placeholder created then destroyed → net zero
    assert_equal initial_comment_count, @creative.comments.count
    assert_not @creative.comments.exists?(content: Collavre::Comment::STREAMING_PLACEHOLDER_CONTENT)
  end

  test "dispatches A2A when AI response mentions another AI agent" do
    # Create a second AI agent
    agent_b = User.create!(
      email: "agentb@ai.local",
      password: "password",
      name: "AgentB",
      llm_vendor: "google",
      llm_model: "gemini-1.5-flash",
      system_prompt: "You are agent B.",
      routing_expression: "true"
    )

    mock_client = Minitest::Mock.new
    def mock_client.chat(messages, tools: [])
      yield "@AgentB: 이 주제에 대해 어떻게 생각해?"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    dispatched = false
    Collavre::SystemEvents::Dispatcher.stub :dispatch, ->(event_name, context, **options) {
      dispatched = true
      assert_equal "comment_created", event_name
      assert_equal "@AgentB: 이 주제에 대해 어떻게 생각해?", context[:comment][:content]
      assert_equal @user.id, context[:workspace_user_id]
      assert_equal "a2a", options[:source]
    } do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    assert dispatched, "Expected A2A dispatch to be called for AI agent mention"
  end

  test "uses the carried human workspace principal for an A2A turn" do
    upstream_agent = User.create!(
      email: "upstream-a2a-agent@ai.local",
      password: SecureRandom.hex(24),
      name: "UpstreamA2AAgent",
      llm_vendor: "google",
      llm_model: "gemini-1.5-flash"
    )
    upstream_reply = @creative.comments.create!(
      content: "A2A request",
      user: upstream_agent,
      topic: @comment.topic,
      skip_dispatch: true
    )
    @task.update!(
      trigger_event_payload: {
        "comment" => { "id" => upstream_reply.id, "content" => upstream_reply.content },
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => upstream_reply.topic_id },
        "workspace_user_id" => @user.id
      }
    )

    mock_client = Minitest::Mock.new
    def mock_client.chat(messages, tools: [])
      yield "Downstream response"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    captured_context = nil
    current_workspace_user = nil
    current_workspace_user_resolved = nil
    client_factory = lambda do |**options|
      captured_context = options[:context]
      current_workspace_user = Current.workspace_user
      current_workspace_user_resolved = Current.workspace_user_resolved
      mock_client
    end

    AiClient.stub :new, client_factory do
      AiAgentService.new(@task).call
    end

    assert_equal @user, captured_context[:workspace_user]
    assert_not_equal upstream_agent, captured_context[:workspace_user]
    assert_equal @user, current_workspace_user
    assert current_workspace_user_resolved
    assert_nil Current.workspace_user
    assert_nil Current.workspace_user_resolved
  end

  test "does not fall back to the creator for an explicitly cleared workspace principal" do
    upstream_agent = users(:ai_bot)
    upstream_reply = @creative.comments.create!(
      content: "Re-anchored A2A request",
      user: upstream_agent,
      topic: @comment.topic,
      skip_dispatch: true
    )
    @task.update!(
      trigger_event_payload: {
        "comment" => { "id" => upstream_reply.id, "content" => upstream_reply.content },
        "creative" => { "id" => @creative.id },
        "workspace_user_id" => nil
      }
    )

    service = AiAgentService.new(@task)
    service.instance_variable_set(:@original_comment, upstream_reply)

    assert_nil service.send(:workspace_user)
  end

  test "carries an explicitly cleared workspace principal across the next A2A hop" do
    downstream_agent = User.create!(
      email: "cleared-principal-downstream@ai.local",
      password: SecureRandom.hex(24),
      name: "ClearedPrincipalDownstream",
      llm_vendor: "google",
      llm_model: "gemini-1.5-flash",
      system_prompt: "Help"
    )
    upstream_reply = @creative.comments.create!(
      content: "Re-anchored A2A request",
      user: @agent,
      topic: @comment.topic,
      skip_dispatch: true
    )
    @task.update!(
      trigger_event_payload: {
        "comment" => { "id" => upstream_reply.id, "content" => upstream_reply.content },
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => upstream_reply.topic_id },
        "workspace_user_id" => nil
      }
    )
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) { |_messages, tools: [], &block| block.call("@#{downstream_agent.name}: continue") }
    mock_client.define_singleton_method(:last_handoff_failed?) { false }
    mock_client.define_singleton_method(:handed_off?) { true }
    dispatched = nil
    current_workspace_user = :unset
    current_workspace_user_resolved = nil
    client_factory = lambda do |**_options|
      current_workspace_user = Current.workspace_user
      current_workspace_user_resolved = Current.workspace_user_resolved
      mock_client
    end

    SystemEvents::Dispatcher.stub(:dispatch, ->(_event_name, payload, **_options) { dispatched = payload }) do
      AiClient.stub(:new, client_factory) { AiAgentService.new(@task).call }
    end

    assert dispatched.key?(:workspace_user_id)
    assert_nil dispatched[:workspace_user_id]
    assert_nil current_workspace_user
    assert current_workspace_user_resolved
  end

  test "does not dispatch A2A when AI response mentions a human user" do
    mock_client = Minitest::Mock.new
    def mock_client.chat(messages, tools: [])
      yield "@One: 확인해 주세요"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    dispatched = false
    Collavre::SystemEvents::Dispatcher.stub :dispatch, ->(*) { dispatched = true } do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    assert_not dispatched, "Should not dispatch A2A for human user mention"
  end

  test "does not dispatch A2A when AI response has no mention" do
    mock_client = Minitest::Mock.new
    def mock_client.chat(messages, tools: [])
      yield "Just a normal response without mentions"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    dispatched = false
    Collavre::SystemEvents::Dispatcher.stub :dispatch, ->(*) { dispatched = true } do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    assert_not dispatched, "Should not dispatch A2A when no mention present"
  end

  test "delegates to ClaudeChannelAdapter for claude_channel_agent" do
    claude_agent = User.create!(
      email: "cc-svc-test@agent.collavre.local",
      password: SecureRandom.hex(32),
      name: "Claude CC",
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      created_by_id: @user.id,
      searchable: false
    )

    topic = @creative.topics.create!(name: "CC Topic", user: @user)
    comment = @creative.comments.create!(content: "Hello CC", user: @user, topic: topic)

    task = Task.create!(
      name: "CC Task",
      status: "running",
      trigger_event_name: "comment_created",
      trigger_event_payload: {
        "comment" => { "id" => comment.id, "content" => comment.content },
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => topic.id }
      },
      agent: claude_agent
    )

    initial_count = @creative.comments.count

    # Use the :test adapter so the enqueued ClaudeChannelPresenceJob is recorded
    # rather than run inline (which, with no live session, would post a disconnect
    # notice and, with one, recurse on its self-re-enqueue).
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    enqueued = nil
    broadcasts = []
    begin
      ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
        result = AiAgentService.new(task).call
        assert_nil result
      end
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs
    ensure
      ActiveJob::Base.queue_adapter = original_adapter
    end

    # No reply comment created (reply comes via API)
    assert_equal initial_count, @creative.comments.count

    # Logs delegated action
    assert task.task_actions.exists?(action_type: "delegated")

    # Broadcast dispatch event
    dispatch = broadcasts.find { |b| b[:data][:type] == "dispatch" }
    assert_not_nil dispatch

    # Drives the chat typing indicator via the presence heartbeat job.
    assert(enqueued.any? { |j| j[:job] == Collavre::ClaudeChannelPresenceJob && j[:args] == [ task.id ] },
           "expected ClaudeChannelPresenceJob enqueued for task #{task.id} to drive the typing indicator")
  end

  test "does not call AiClient for claude_channel_agent" do
    claude_agent = User.create!(
      email: "cc-noclient@agent.collavre.local",
      password: SecureRandom.hex(32),
      name: "Claude NoClient",
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      created_by_id: @user.id,
      searchable: false
    )

    topic = @creative.topics.create!(name: "NoClient Topic", user: @user)
    comment = @creative.comments.create!(content: "Test", user: @user, topic: topic)

    task = Task.create!(
      name: "NoClient Task",
      status: "running",
      trigger_event_name: "comment_created",
      trigger_event_payload: {
        "comment" => { "id" => comment.id, "content" => comment.content },
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => topic.id }
      },
      agent: claude_agent
    )

    ai_client_called = false
    AiClient.stub :new, ->(*) { ai_client_called = true; raise "Should not be called" } do
      ActionCable.server.stub :broadcast, ->(*) { } do
        AiAgentService.new(task).call
      end
    end

    assert_not ai_client_called, "AiClient should not be instantiated for Claude Channel agents"
  end

  test "saves partial content when cancelled" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |messages, tools: [], &block|
      block.call("Partial ")
      block.call("content")
      Task.find(task_id).update!(status: "cancelled")
      block.call(" more")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    original_interval = Collavre::AiAgent::AgentLifecycleManager::CANCEL_CHECK_INTERVAL
    Collavre::AiAgent::AgentLifecycleManager.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    Collavre::AiAgent::AgentLifecycleManager.const_set(:CANCEL_CHECK_INTERVAL, 0)

    assert_raises(Collavre::CancelledError) do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    Collavre::AiAgent::AgentLifecycleManager.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    Collavre::AiAgent::AgentLifecycleManager.const_set(:CANCEL_CHECK_INTERVAL, original_interval)

    # Placeholder should contain partial content
    reply = @creative.comments.where(user: @agent).order(:created_at).last
    assert reply.content.start_with?("Partial content")
    assert @task.task_actions.exists?(action_type: "cancelled")
  end

  # StuckDetectorJob marks a hung task `failed` from another process while
  # this worker is still streaming. The worker must notice at the next chunk
  # and leave through the CancelledError recovery path instead of streaming
  # on — in production a thread kept streaming for an hour after its row was
  # already failed, holding one of the worker's threads the whole time.
  test "stops streaming when the task was failed externally" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("Partial ")
      Task.find(task_id).update!(status: "failed")
      block.call("content")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    with_immediate_cancel_checks do
      assert_raises(Collavre::CancelledError) do
        AiClient.stub :new, mock_client do
          AiAgentService.new(@task).call
        end
      end
    end

    assert_equal "failed", @task.reload.status,
      "the externally-written status must not be overwritten"
    failure_action = @task.task_actions.find_by!(action_type: "failed")
    assert_equal "Task failed externally", failure_action.payload["message"]
    assert_not @task.task_actions.exists?(action_type: "cancelled"),
               "an automatic failure must not be attributed to a user"
  end

  # The service is the only place that sees both the delivery record it wrote
  # and the client that failed to hand it over. AiClient#chat swallows the
  # provider error and the job then marks the task `done`, so unless the
  # failure is written down here the turn ends in a status every reader counts
  # as delivery — and the dispatches it discarded never come back.
  test "records a failed handoff when the client never reached the provider" do
    mock_client = Minitest::Mock.new
    def mock_client.chat(messages, tools: [])
      yield "\n\n⚠️ AI Error: [StandardError] connection refused"
    end
    def mock_client.last_handoff_failed? = true
    def mock_client.handed_off? = false

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    assert Collavre::Orchestration::DeliveryRecord.handoff_failed?(@task.reload.trigger_event_payload)
  end

  # Control: an ordinary turn records nothing, so the flag cannot be what every
  # completed turn carries.
  test "records no failed handoff when the client answered" do
    mock_client = Minitest::Mock.new
    def mock_client.chat(messages, tools: [])
      yield "An answer"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    assert_not Collavre::Orchestration::DeliveryRecord.handoff_failed?(@task.reload.trigger_event_payload)
  end

  # A user pressing Stop mid-answer ends the turn `cancelled`, which every
  # reader counts as undelivered — but the provider has the payload by then, and
  # with it the comments this turn swallowed. Nothing in the row says which side
  # of the handoff the Stop landed on; the client is the only object that knows.
  test "records the handoff when the turn is stopped after content streamed" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("Partial ")
      Task.find(task_id).update!(status: "cancelled")
      block.call("content")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    with_immediate_cancel_checks do
      assert_raises(Collavre::CancelledError) do
        AiClient.stub :new, mock_client do
          AiAgentService.new(@task).call
        end
      end
    end

    assert Collavre::Orchestration::DeliveryRecord.handed_off?(@task.reload.trigger_event_payload)
  end

  # Control: the record follows the client's answer, not the fact of
  # cancellation. A turn stopped before its request got anywhere delivered
  # nothing, and the dispatches it discarded still have to come back.
  test "records no handoff when the turn is stopped before anything reached the provider" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      Task.find(task_id).update!(status: "cancelled")
      block.call("")
      block.call("late")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = false

    with_immediate_cancel_checks do
      assert_raises(Collavre::CancelledError) do
        AiClient.stub :new, mock_client do
          AiAgentService.new(@task).call
        end
      end
    end

    assert_not Collavre::Orchestration::DeliveryRecord.handed_off?(@task.reload.trigger_event_payload)
  end

  # llm_request_timeout_seconds bounds ONE provider request; a turn is a loop
  # of requests (LLM -> tools -> LLM ...), so its wall clock is otherwise
  # unbounded. With the deadline already in the past, the very next chunk
  # must end the turn as failed through the cancellation recovery path.
  test "fails the turn when the wall-clock deadline is exceeded" do
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("Partial ")
      block.call("content")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    with_immediate_cancel_checks do
      Collavre::SystemSetting.stub :ai_agent_turn_deadline_seconds, 0 do
        assert_raises(Collavre::TurnDeadlineError) do
          AiClient.stub :new, mock_client do
            AiAgentService.new(@task).call
          end
        end
      end
    end

    assert_equal "failed", @task.reload.status
    deadline_action = @task.task_actions.find_by!(action_type: "failed")
    assert_equal "Turn exceeded the 0s deadline", deadline_action.payload["message"]
  end

  test "force-checks terminal status after the provider completes" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &_block|
      # Simulate StuckDetector winning while the provider's final response is
      # in flight, less than one throttle interval after the prior checkpoint.
      Collavre::Orchestration::DeliveryRecord.fail_while_worker_settles!(Task.find(task_id))
      nil
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    assert_raises(Collavre::CancelledError) do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    assert_equal "failed", @task.reload.status
    assert_not @task.task_actions.exists?(action_type: "completion"),
               "an externally failed turn must not enter response finalization"
  end

  test "force-checks terminal status immediately before starting the provider call" do
    task_id = @task.id
    provider_called = false
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &_block|
      provider_called = true
      "must not run"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = false

    service = AiAgentService.new(@task)
    service.define_singleton_method(:build_ai_client) do |_system_prompt|
      Collavre::Orchestration::DeliveryRecord.fail_while_worker_settles!(Task.find(task_id))
      mock_client
    end

    assert_raises(Collavre::CancelledError) { service.call }

    refute provider_called,
           "a task that ended during prompt preparation must not reach the provider"
    assert_equal "failed", @task.reload.status
  end

  test "rechecks terminal status after response finalization before A2A dispatch" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("An answer")
      "An answer"
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    service = AiAgentService.new(@task)
    service.define_singleton_method(:finalize_response) do
      Collavre::Orchestration::DeliveryRecord.fail_while_worker_settles!(Task.find(task_id))
      nil
    end
    dispatched = false
    service.define_singleton_method(:dispatch_a2a) { |_comment| dispatched = true }

    assert_raises(Collavre::CancelledError) do
      AiClient.stub :new, mock_client do
        service.call
      end
    end

    assert_equal "failed", @task.reload.status
    refute dispatched, "a finalized response must not dispatch after the task became terminal"
  end

  # The delta callback above is the deadline's only checkpoint on the text
  # path — and a tool-only turn has no text: AiClient skips contentless
  # tool-call chunks above the yield, so the streaming block never runs. The
  # service must hand the client its lifecycle check to run at the tool-call
  # boundary; otherwise a looping tool-only turn outlives any deadline while
  # holding its worker thread.
  test "tool-only turns hit the deadline at the tool-call boundary" do
    before_tool_call = nil
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      # A tool-only loop as AiClient drives it: no delta ever reaches the
      # streaming block; the injected boundary check is all the turn crosses.
      before_tool_call.call
      block.call("never reached")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    build_client = lambda do |**kwargs|
      before_tool_call = kwargs.fetch(:before_tool_call)
      mock_client
    end

    with_immediate_cancel_checks do
      Collavre::SystemSetting.stub :ai_agent_turn_deadline_seconds, 0 do
        assert_raises(Collavre::TurnDeadlineError) do
          AiClient.stub :new, build_client do
            AiAgentService.new(@task).call
          end
        end
      end
    end

    assert_equal "failed", @task.reload.status
    deadline_action = @task.task_actions.find_by!(action_type: "failed")
    assert_equal "Turn exceeded the 0s deadline", deadline_action.payload["message"]
  end

  test "handles a deadline raised while generating an approval summary" do
    task = @task
    deadline_error = Collavre::TurnDeadlineError.new(60)
    tool_call = OpenStruct.new(name: "creative_update", arguments: { "id" => 1 }, id: "call-1")
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &_block|
      raise Collavre::ApprovalPendingError.new(tool_call: tool_call, task: task)
    end
    mock_client.define_singleton_method(:ask) do |_prompt|
      Collavre::Orchestration::DeliveryRecord.fail_while_worker_settles!(task)
      raise deadline_error
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    error = assert_raises(Collavre::TurnDeadlineError) do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    assert_same deadline_error, error
    assert_equal "failed", @task.reload.status
    deadline_action = @task.task_actions.find_by!(action_type: "failed")
    assert_equal "Turn exceeded the 60s deadline", deadline_action.payload["message"]
    assert_not @task.task_actions.exists?(action_type: "approval_requested"),
               "a turn that hit its deadline must not be parked for approval"
  end

  # A bare `update!(status: "failed")` on deadline would fire Task's
  # after_update_commit callback before mark_handed_off! ever runs (that
  # happens later, in execute_llm_conversation's ensure) — so the callback
  # would read a payload with no handoff evidence yet and restore a dispatch
  # this turn actually delivered, producing a duplicate reply on a busy topic.
  # The deadline path must instead go through
  # Orchestration::DeliveryRecord.fail_while_worker_settles!, which marks the
  # row so the callback defers the decision to AiAgentJob's ensure once real
  # handoff evidence exists — see ai_agent_job.rb's worker_settling? branch.
  test "does not restore a dropped dispatch at the moment the deadline fires" do
    other_comment = @creative.comments.create!(content: "Second comment", user: @user)
    assert Collavre::Orchestration::DeliveryRecord.claim_drop!(@task, other_comment.id),
           "premise: another process refused a dispatch against this in-flight turn"

    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |_messages, tools: [], &block|
      block.call("Partial ")
      block.call("content")
    end
    def mock_client.last_handoff_failed? = false
    def mock_client.handed_off? = true

    with_immediate_cancel_checks do
      Collavre::SystemSetting.stub :ai_agent_turn_deadline_seconds, 0 do
        assert_raises(Collavre::TurnDeadlineError) do
          AiClient.stub :new, mock_client do
            AiAgentService.new(@task).call
          end
        end
      end
    end

    assert_equal "failed", @task.reload.status
    assert Collavre::Orchestration::DeliveryRecord.worker_settling?(@task.trigger_event_payload),
           "the deadline path must leave the worker-settling marker for AiAgentJob's ensure to resolve"
    assert_empty Collavre::Orchestration::DeliveryRecord.restored_ids_in(@task.trigger_event_payload),
                 "the dispatch must wait for the job's settle path, not be restored at deadline time"
  end

  def with_immediate_cancel_checks
    manager = Collavre::AiAgent::AgentLifecycleManager
    original = manager::CANCEL_CHECK_INTERVAL
    manager.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    manager.const_set(:CANCEL_CHECK_INTERVAL, 0)
    yield
  ensure
    manager.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    manager.const_set(:CANCEL_CHECK_INTERVAL, original)
  end
end
