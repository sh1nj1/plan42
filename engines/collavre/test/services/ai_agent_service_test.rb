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
    original_dispatch = Collavre::SystemEvents::Dispatcher.method(:dispatch)

    Collavre::SystemEvents::Dispatcher.stub :dispatch, ->(event_name, context) {
      dispatched = true
      assert_equal "comment_created", event_name
      assert_equal "@AgentB: 이 주제에 대해 어떻게 생각해?", context[:comment][:content]
    } do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    assert dispatched, "Expected A2A dispatch to be called for AI agent mention"
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
