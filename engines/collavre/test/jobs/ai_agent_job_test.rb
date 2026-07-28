require "test_helper"

class AiAgentJobTest < ActiveJob::TestCase
  setup do
    @owner = users(:one)
    @creative = Creative.create!(user: @owner, description: "Test Creative")
    @comment = Comment.create!(creative: @creative, user: @owner, content: "Hello")

    @agent = User.create!(
      email: "job_test_agent@example.com",
      name: "Job Agent",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-1.5-flash",
      routing_expression: "true",
      searchable: true
    )

    @context = {
      "creative" => { "id" => @creative.id },
      "comment" => { "id" => @comment.id, "content" => "Hello" }
    }
  end

  class FakeAiClient
    def initialize(*args); end
    def chat(contents, tools: [], &block)
      block.call("AI Response") if block
      "AI Response"
    end

    def last_handoff_failed? = false
    def handed_off? = true
  end

  test "creates task and executes service" do
    AiClient.stub :new, FakeAiClient.new do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "test_event", @context)
      end
    end

    # Verify Task creation
    task = Task.last
    assert_equal @agent.id, task.agent.id
    assert_equal "test_event", task.trigger_event_name
    assert_equal "done", task.status

    # Verify Task Actions
    assert_equal 4, task.task_actions.count
    assert_equal [ "start", "prompt_generated", "completion", "reply_created" ], task.task_actions.pluck(:action_type)

    # Verify final comment is created (not a streaming placeholder)
    reply = @creative.comments.order(:created_at).last
    assert_equal "AI Response", reply.content
    assert_equal @agent.id, reply.user_id
  end

  test "handles service errors" do
    # Mock AiClient to raise error
    AiClient.stub :new, ->(*args) { raise StandardError, "AI Error" } do
      assert_raises(StandardError) do
        AiAgentJob.perform_now(@agent.id, "test_event", @context)
      end
    end

    task = Task.last
    assert_equal "failed", task.status
  end

  class EmptyAiClient
    def initialize(*args); end
    def chat(contents, tools: [], &block)
      # Do not yield any content
      ""
    end

    def last_handoff_failed? = false
    # An empty answer is an answer: the provider had the payload, as the real
    # client reports for one.
    def handed_off? = true
  end

  test "does not create reply if AI response is empty" do
    AiClient.stub :new, EmptyAiClient.new do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "test_event", @context)
      end
    end

    task = Task.last
    assert_equal "done", task.status

    # Verify Task Actions - reply_created should be missing
    assert_equal 3, task.task_actions.count
    assert_equal [ "start", "prompt_generated", "completion" ], task.task_actions.pluck(:action_type)

    # Verify no new comment created (no placeholder, no reply)
    assert_equal 1, @creative.comments.count # Only the initial comment
    assert_not @creative.comments.exists?(content: Collavre::Comment::STREAMING_PLACEHOLDER_CONTENT)
  end

  class PromptCaptureClient
    attr_reader :captured_system_prompt
    attr_reader :captured_context

    def initialize(vendor:, model:, system_prompt:, llm_api_key:, gateway_url: nil, context: {})
      @captured_system_prompt = system_prompt
      @captured_context = context
    end

    def chat(contents, tools: [], &block)
      block.call("AI Response") if block
      "AI Response"
    end

    def last_handoff_failed? = false
    def handed_off? = true
  end

  test "renders system prompt with liquid context" do
    @agent.update!(system_prompt: "You are helpful for {{ creative.description }}")

    capture_client = nil

    AiClient.stub :new, ->(**kwargs) { capture_client = PromptCaptureClient.new(**kwargs) } do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "test_event", @context)
      end
    end

    assert_equal "You are helpful for Test Creative", capture_client.captured_system_prompt
  end

  class MessageCaptureClient
    attr_reader :captured_messages_data

    def initialize(*args); end

    def chat(messages_data, tools: [], &block)
      @captured_messages_data = messages_data
      block.call("AI Response") if block
      "AI Response"
    end

    def last_handoff_failed? = false
    def handed_off? = true

    # Extract the messages array from the Hash (or return as-is for backward compat)
    def captured_messages
      @captured_messages_data.is_a?(Hash) ? @captured_messages_data[:messages] : @captured_messages_data
    end
  end

  test "includes chat history in messages" do
    # Create some history
    # 1. User comment
    Comment.create!(creative: @creative, user: @owner, content: "Previous user message", created_at: 10.minutes.ago)
    # 2. Agent comment (simulated)
    Comment.create!(creative: @creative, user: @agent, content: "Previous agent message", created_at: 5.minutes.ago)

    capture_client = nil

    AiClient.stub :new, ->(**kwargs) { capture_client = MessageCaptureClient.new(**kwargs) } do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "test_event", @context)
      end
    end

    messages = capture_client.captured_messages

    # Expected messages:
    # 1. Creative context (system/user)
    # 2. Previous user message
    # 3. Previous agent message
    # 4. Current trigger message

    # Note: The exact index depends on implementation details (e.g. creative context might be first)
    # Let's check for existence and order

    user_msg_idx = messages.index { |m| m[:role] == "user" && m[:parts][0][:text].include?("Previous user message") }
    agent_msg_idx = messages.index { |m| m[:role] == "model" && m[:parts][0][:text].include?("Previous agent message") }
    current_msg_idx = messages.index { |m| m[:role] == "user" && m[:parts][0][:text].include?("Hello") }

    assert user_msg_idx, "Previous user message not found"
    assert agent_msg_idx, "Previous agent message not found"
    assert current_msg_idx, "Current message not found"

    assert user_msg_idx < agent_msg_idx
    assert agent_msg_idx < current_msg_idx
  end

  test "skips execution when task is already cancelled before job runs" do
    task = Task.create!(
      name: "Response to test_event",
      status: "running",
      trigger_event_name: "test_event",
      trigger_event_payload: @context,
      agent: @agent
    )

    # Pre-cancel the task to simulate comment deletion before job starts
    task.update!(status: "cancelled")

    AiClient.stub :new, FakeAiClient.new do
      AiAgentJob.perform_now(task)
    end

    # Task should remain cancelled — job should not have run
    assert_equal "cancelled", task.reload.status
    assert_equal 0, task.task_actions.count
  end

  test "cancels during streaming when task status changes to cancelled" do
    task = Task.create!(
      name: "Response to test_event",
      status: "running",
      trigger_event_name: "test_event",
      trigger_event_payload: @context,
      agent: @agent
    )

    # Client that cancels the task mid-stream to simulate user deleting message
    cancelling_client = Class.new do
      define_method(:initialize) { |*args, **kwargs| }
      define_method(:chat) do |contents, tools: [], &block|
        block.call("chunk 0 ") if block
        # Simulate user deleting their comment → task gets cancelled
        task.update!(status: "cancelled")
        block.call("chunk 1 ") if block
        "chunk 0 chunk 1 "
      end
      define_method(:last_handoff_failed?) { false }
      # Streamed before the stop, as the real client records.
      define_method(:handed_off?) { true }
    end

    # Temporarily set cancel check interval to 0 so it checks on every chunk
    lifecycle_klass = Collavre::AiAgent::AgentLifecycleManager
    original_interval = lifecycle_klass::CANCEL_CHECK_INTERVAL
    lifecycle_klass.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    lifecycle_klass.const_set(:CANCEL_CHECK_INTERVAL, 0)

    AiClient.stub :new, cancelling_client.new do
      AiAgentJob.perform_now(task)
    end

    assert_equal "cancelled", task.reload.status
    assert_includes task.task_actions.pluck(:action_type), "cancelled"
  ensure
    lifecycle_klass = Collavre::AiAgent::AgentLifecycleManager
    lifecycle_klass.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    lifecycle_klass.const_set(:CANCEL_CHECK_INTERVAL, original_interval)
  end

  test "triggers dequeue_next_for_topic on completion" do
    topic = Topic.create!(name: "Test Topic", creative: @creative, user: @owner)
    context_with_topic = @context.merge("topic" => { "id" => topic.id })

    # Create a queued task waiting in line
    queued_task = Task.create!(
      name: "Queued task", status: "queued",
      trigger_event_name: "comment_created",
      trigger_event_payload: context_with_topic,
      agent: @agent, topic_id: topic.id,
      creative_id: @creative.id
    )

    AiClient.stub :new, FakeAiClient.new do
      AiAgentJob.perform_now(@agent.id, "test_event", context_with_topic)
    end

    # The completed task should have triggered dequeue — queued task is no longer queued
    # (inline adapter runs it immediately so it progresses past "pending")
    assert_not_equal "queued", queued_task.reload.status
  end

  test "triggers dequeue_next_for_topic on failure" do
    topic = Topic.create!(name: "Test Topic", creative: @creative, user: @owner)
    context_with_topic = @context.merge("topic" => { "id" => topic.id })

    queued_task = Task.create!(
      name: "Queued task", status: "queued",
      trigger_event_name: "comment_created",
      trigger_event_payload: context_with_topic,
      agent: @agent, topic_id: topic.id,
      creative_id: @creative.id
    )

    AiClient.stub :new, ->(*args) { raise StandardError, "AI Error" } do
      assert_raises(StandardError) do
        AiAgentJob.perform_now(@agent.id, "test_event", context_with_topic)
      end
    end

    # Dequeue should have been triggered despite failure
    assert_not_equal "queued", queued_task.reload.status
  end

  test "fetches latest comments when history exceeds limit" do
    # Create 60 comments
    60.times do |i|
      Comment.create!(creative: @creative, user: @owner, content: "Message #{i}", created_at: (60 - i).minutes.ago)
    end

    capture_client = nil

    AiClient.stub :new, ->(**kwargs) { capture_client = MessageCaptureClient.new(**kwargs) } do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "test_event", @context)
      end
    end

    messages = capture_client.captured_messages
    message_texts = messages.map { |m| m[:parts][0][:text] }

    # Should include "Message 59" (most recent, with speaker label)
    assert message_texts.any? { |t| t.include?("Message 59") }, "Expected message_texts to include 'Message 59'"

    # Should NOT include "Message 0" (oldest)
    assert_not message_texts.any? { |t| t.include?("Message 0") }, "Expected message_texts NOT to include 'Message 0'"

    # Verify we have roughly 50 history items + creative context + trigger payload
    # Exact count depends on implementation details, but should be around 52-53
    assert messages.count > 40
    assert messages.count < 60
  end

  test "skips duplicate execution when agent already has running task for same comment" do
    # Create an existing running task for the same agent + comment
    Task.create!(
      name: "Response to comment_created",
      status: "running",
      trigger_event_name: "comment_created",
      trigger_event_payload: @context,
      agent: @agent,
      topic_id: nil
    )

    initial_task_count = Task.where(agent_id: @agent.id).count

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "comment_created", @context)
      end
    end

    # No new task should have been created
    assert_equal initial_task_count, Task.where(agent_id: @agent.id).count,
      "Expected no new task when duplicate running task exists for same comment"
  end

  test "delayed job skips dispatch when the topic was assigned to another agent during the delay" do
    # Scheduler returns :delayed for a busy / rate-limited agent and enqueues
    # with agent.id — no Task row exists yet, so there is nothing to cancel when
    # the assignment lands. Nothing re-matches before execution either, so
    # without a check here a demoted agent speaks in a topic that is now
    # exclusively someone else's.
    topic = Topic.create!(creative: @creative, name: "assigned-during-delay", user: @owner)
    primary = User.create!(
      email: "assigned_primary@example.com", name: "Assigned Primary",
      password: "password", llm_vendor: "google", llm_model: "gemini-1.5-flash",
      searchable: true
    )
    topic.set_primary_agent!(primary)

    context = @context.merge("topic" => { "id" => topic.id })
    tasks_before = Task.where(agent_id: @agent.id).count

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      AiAgentJob.perform_now(@agent.id, "comment_created", context)
    end

    assert_equal tasks_before, Task.where(agent_id: @agent.id).count,
      "an agent the topic assignment now excludes must not run"
  end

  test "delayed job still dispatches when the assignment names this agent" do
    topic = Topic.create!(creative: @creative, name: "assigned-to-me", user: @owner)
    topic.set_primary_agent!(@agent)

    context = @context.merge("topic" => { "id" => topic.id })
    tasks_before = Task.where(agent_id: @agent.id).count

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      AiAgentJob.perform_now(@agent.id, "comment_created", context)
    end

    assert_equal tasks_before + 1, Task.where(agent_id: @agent.id).count,
      "the assigned primary agent must still run"
  end

  test "skips duplicate execution when agent has delegated Claude Channel task for same comment" do
    # A delegated task is still in-flight (waiting on external MCP reply);
    # re-dispatching the same comment would produce duplicate replies.
    Task.create!(
      name: "Response to comment_created",
      status: "delegated",
      trigger_event_name: "comment_created",
      trigger_event_payload: @context,
      agent: @agent,
      topic_id: nil
    )

    initial_task_count = Task.where(agent_id: @agent.id).count

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "comment_created", @context)
      end
    end

    assert_equal initial_task_count, Task.where(agent_id: @agent.id).count,
      "Expected no new task when duplicate delegated task exists for same comment"
  end

  test "releases resources in ensure block on success" do
    AiClient.stub :new, FakeAiClient.new do
      AiAgentJob.perform_now(@agent.id, "test_event", @context)
    end

    tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
    assert_equal 0, tracker.active_jobs,
      "Expected active_jobs to be 0 after successful completion"
  end

  test "releases resources in ensure block on error" do
    AiClient.stub :new, ->(*args) { raise StandardError, "AI Error" } do
      assert_raises(StandardError) do
        AiAgentJob.perform_now(@agent.id, "test_event", @context)
      end
    end

    tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
    assert_equal 0, tracker.active_jobs,
      "Expected active_jobs to be 0 after error"
  end

  test "does not release resources on approval pending" do
    # Stub AiAgentService to raise ApprovalPendingError directly
    fake_service = Minitest::Mock.new
    fake_service.expect(:call, nil) { raise Collavre::ApprovalPendingError }

    Collavre::AiAgentService.stub :new, ->(_task) { fake_service } do
      AiAgentJob.perform_now(@agent.id, "test_event", @context)
    end

    tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
    assert_operator tracker.active_jobs, :>, 0,
      "Expected active_jobs > 0 when approval is pending"
  end

  test "approval-pending slot is keyed by task.id so external cancel can release it" do
    # The job exits via ApprovalPendingError holding the slot, then later runs
    # (resume / cancel / stuck recovery) all release! by task.id. The held slot
    # must therefore be keyed by the stable task.id, not the per-run job_id, or
    # those releases no-op and the slot leaks until the cache expiry.
    captured_task = nil
    fake_service = Minitest::Mock.new
    fake_service.expect(:call, nil) { raise Collavre::ApprovalPendingError }

    Collavre::AiAgentService.stub :new, ->(task) { captured_task = task; fake_service } do
      AiAgentJob.perform_now(@agent.id, "test_event", @context)
    end

    tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
    assert_operator tracker.active_jobs, :>, 0, "Expected the slot to be held while approval is pending"

    tracker.release!(captured_task.id)
    assert_equal 0, tracker.active_jobs,
      "Expected release!(task.id) to free the approval-pending slot"
  end

  test "allows execution when existing task for same comment is done" do
    # Create a completed task for the same agent + comment
    Task.create!(
      name: "Response to comment_created",
      status: "done",
      trigger_event_name: "comment_created",
      trigger_event_payload: @context,
      agent: @agent,
      topic_id: nil
    )

    initial_task_count = Task.where(agent_id: @agent.id).count

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      perform_enqueued_jobs do
        AiAgentJob.perform_later(@agent.id, "comment_created", @context)
      end
    end

    # A new task should have been created (the done one doesn't block)
    assert_operator Task.where(agent_id: @agent.id).count, :>, initial_task_count,
      "Expected new task when existing task is done"
  end

  test "claude channel workflow subtask without topic fails and notifies parent" do
    claude_agent = User.create!(
      email: "cc-workflow-agent@agent.collavre.local",
      name: "Claude Workflow Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      # Online session — without this, the resumed-task offline guard
      # (commit fixing P2 "Guard queued Claude jobs when session offline")
      # would short-circuit before the adapter's UndeliverableError fires.
      routing_expression: "true",
      created_by_id: @owner.id,
      searchable: false
    )

    parent_creative = Creative.create!(user: @owner, description: "Workflow Parent")
    parent_task = Task.create!(
      name: "Workflow Parent",
      status: "running",
      agent: @owner,
      creative_id: parent_creative.id
    )

    # Workflow subtasks are built without a topic — see WorkflowExecutor#build_subtask_context.
    workflow_context = {
      "creative" => { "id" => @creative.id },
      "comment" => { "id" => @comment.id, "content" => "Run subtask" }
    }

    fail_called_with = nil
    fake_executor = Class.new do
      define_method(:fail_subtask!) do |sub_task, error_message: nil|
        fail_called_with = { sub_task: sub_task, error_message: error_message }
      end
    end.new

    Collavre::Comments::WorkflowExecutor.stub :new, fake_executor do
      assert_raises(Collavre::AiAgent::ClaudeChannelAdapter::UndeliverableError) do
        # Create the task explicitly with parent_task_id; perform_now exercises the job path.
        sub_task = Task.create!(
          name: "Claude subtask",
          status: "running",
          agent: claude_agent,
          parent_task_id: parent_task.id,
          creative_id: @creative.id,
          trigger_event_payload: workflow_context
        )
        AiAgentJob.perform_now(sub_task)
      end
    end

    sub_task = Task.where(agent_id: claude_agent.id, parent_task_id: parent_task.id).last
    assert_equal "failed", sub_task.status
    assert_not_nil fail_called_with, "Expected WorkflowExecutor#fail_subtask! to be invoked"
    assert_equal sub_task.id, fail_called_with[:sub_task].id
    assert_match(/Claude Channel/, fail_called_with[:error_message].to_s)
  end

  test "claude channel task is delegated before adapter deliver" do
    claude_agent = User.create!(
      email: "cc-race-agent@agent.collavre.local",
      name: "Claude Race Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      routing_expression: "true",
      created_by_id: @owner.id,
      searchable: false
    )

    topic = Topic.create!(creative: @creative, name: "cc-race", user: @owner)
    context = {
      "creative" => { "id" => @creative.id },
      "topic" => { "id" => topic.id },
      "comment" => { "id" => @comment.id, "content" => "Race test" }
    }

    status_at_deliver = nil
    delivered = false
    fake_adapter = Class.new do
      define_method(:initialize) { |agent:, context:, task: nil| @agent = agent; @context = context; @task = task }
      define_method(:deliver) do
        status_at_deliver = Task.where(agent_id: @agent.id).order(:created_at).last&.status
        delivered = true
        nil
      end
    end

    Collavre::AiAgent::ClaudeChannelAdapter.stub :new, ->(**kw) { fake_adapter.new(**kw) } do
      AiAgentJob.perform_now(claude_agent.id, "comment_created", context)
    end

    assert delivered, "Expected ClaudeChannelAdapter#deliver to be invoked"
    assert_equal "delegated", status_at_deliver,
      "Task must be in 'delegated' state before the MCP dispatch so a fast reply can find it"

    task = Task.where(agent_id: claude_agent.id).last
    assert_equal "delegated", task.status
  end

  test "claude channel job skips dispatch when task cancelled between reserve and delegated" do
    # Simulates AgentsController#destroy cancelling a running Claude Channel
    # task while AiAgentJob#perform is between tracker.reserve! and the
    # running → delegated transition. The atomic `WHERE status = 'running'`
    # UPDATE finds no rows to flip when status has already moved to
    # "cancelled", so the job skips dispatch instead of overwriting the
    # external cancel and broadcasting to a clientless stream.
    claude_agent = User.create!(
      email: "cc-cancel-race-agent@agent.collavre.local",
      name: "Claude Cancel Race Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      created_by_id: @owner.id,
      searchable: false
    )

    topic = Topic.create!(creative: @creative, name: "cc-cancel-race", user: @owner)
    task = Collavre::Task.create!(
      name: "Pre-existing running task",
      status: "running",
      trigger_event_name: "comment_created",
      agent: claude_agent,
      topic_id: topic.id,
      creative_id: @creative.id
    )

    # Fake tracker that simulates AgentsController#destroy landing between
    # tracker.reserve! and the running → delegated transition by flipping
    # the task to "cancelled" inside reserve!.
    fake_tracker = Object.new
    fake_tracker.define_singleton_method(:reserve!) do |_resource_id, **_opts|
      task.update!(status: "cancelled")
      true
    end
    fake_tracker.define_singleton_method(:release!) { |_resource_id, **_opts| true }

    delivered = false
    fake_adapter = Class.new do
      define_method(:initialize) { |agent:, context:, task: nil| }
      define_method(:deliver) { delivered = true; nil }
    end

    Collavre::Orchestration::ResourceTracker.stub :for, ->(_agent) { fake_tracker } do
      Collavre::AiAgent::ClaudeChannelAdapter.stub :new, ->(**kw) { fake_adapter.new(**kw) } do
        AiAgentJob.perform_now(task)
      end
    end

    assert_equal "cancelled", task.reload.status,
      "task must stay cancelled — job must not overwrite with 'delegated'"
    refute delivered, "ClaudeChannelAdapter#deliver must not run after external cancel"
  end

  test "claude channel delayed job skips dispatch when session unregistered during delay" do
    # Simulates Scheduler returning :delayed for a busy / rate-limited Claude
    # Channel agent. Scheduler enqueues AiAgentJob with agent.id (no Task row
    # yet). During the delay, the MCP session unregisters and
    # AgentsController#destroy / AgentChannel#unsubscribed clears
    # routing_expression. When the delayed job fires, the agent_id-keyed path
    # must NOT create a Task, flip it to "delegated", or invoke the adapter —
    # there is no live client to receive the broadcast.
    claude_agent = User.create!(
      email: "cc-delayed-offline-agent@agent.collavre.local",
      name: "Claude Delayed Offline Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      routing_expression: nil,
      created_by_id: @owner.id,
      searchable: false
    )

    topic = Topic.create!(creative: @creative, name: "cc-delayed-offline", user: @owner)
    context = {
      "creative" => { "id" => @creative.id },
      "topic" => { "id" => topic.id },
      "comment" => { "id" => @comment.id, "content" => "Delayed test" }
    }

    delivered = false
    fake_adapter = Class.new do
      define_method(:initialize) { |agent:, context:, task: nil| }
      define_method(:deliver) { delivered = true; nil }
    end

    tasks_before = Task.where(agent_id: claude_agent.id).count

    Collavre::AiAgent::ClaudeChannelAdapter.stub :new, ->(**kw) { fake_adapter.new(**kw) } do
      AiAgentJob.perform_now(claude_agent.id, "comment_created", context)
    end

    refute delivered,
      "ClaudeChannelAdapter#deliver must not run for an unregistered Claude Channel session"
    assert_equal tasks_before, Task.where(agent_id: claude_agent.id).count,
      "no Task row should be created for an offline Claude Channel session"
  end

  test "claude channel queued task skips dispatch when session went offline before dequeue" do
    # Topic-concurrency queueing path: Scheduler returns :queued, a Task row
    # is created and held in queued state. Later, dequeue_next_for_topic
    # (after another task completes or stuck recovery drains the queue)
    # promotes the task and calls AiAgentJob.perform_later(task) — entering
    # the Task branch of perform. If AgentChannel#unsubscribed cleared
    # routing_expression while the task was queued (WS drop without
    # DELETE /agent/:id), the broadcast would otherwise land in a clientless
    # agent:user:<id> stream — held until stuck recovery.
    claude_agent = User.create!(
      email: "cc-queued-offline-agent@agent.collavre.local",
      name: "Claude Queued Offline Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      routing_expression: nil,
      created_by_id: @owner.id,
      searchable: false
    )

    topic = Topic.create!(creative: @creative, name: "cc-queued-offline", user: @owner)
    queued = Task.create!(
      name: "Resumed-from-queue",
      status: "pending",
      agent: claude_agent,
      topic_id: topic.id,
      creative_id: @creative.id,
      trigger_event_payload: {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => topic.id },
        "comment" => { "id" => @comment.id }
      }
    )

    delivered = false
    fake_adapter = Class.new do
      define_method(:initialize) { |agent:, context:, task: nil| }
      define_method(:deliver) { delivered = true; nil }
    end

    Collavre::AiAgent::ClaudeChannelAdapter.stub :new, ->(**kw) { fake_adapter.new(**kw) } do
      AiAgentJob.perform_now(queued)
    end

    refute delivered,
      "ClaudeChannelAdapter#deliver must not run when the resumed task's session is offline"
    assert_equal "cancelled", queued.reload.status,
      "the offline-resumed task must be cancelled so it does not leak slots / queue space"
  end

  test "claude channel offline-resumed workflow subtask fails parent workflow" do
    # WorkflowExecutor builds subtasks with parent_task_id and no topic
    # (see WorkflowExecutor#build_subtask_context). If the resumed task's
    # session went offline (routing_expression blank) before the job fires,
    # the offline guard must not only cancel the child but also propagate
    # failure to the parent via WorkflowExecutor#fail_subtask! — otherwise
    # the parent workflow stays "running" indefinitely because no rescue
    # path runs (we never raise).
    claude_agent = User.create!(
      email: "cc-offline-subtask-agent@agent.collavre.local",
      name: "Claude Offline Subtask Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      routing_expression: nil,
      created_by_id: @owner.id,
      searchable: false
    )

    parent_creative = Creative.create!(user: @owner, description: "Offline Workflow Parent")
    parent_task = Task.create!(
      name: "Offline Workflow Parent",
      status: "running",
      agent: @owner,
      creative_id: parent_creative.id
    )

    workflow_context = {
      "creative" => { "id" => @creative.id },
      "comment" => { "id" => @comment.id, "content" => "Offline subtask" }
    }

    sub_task = Task.create!(
      name: "Claude offline subtask",
      status: "pending",
      agent: claude_agent,
      parent_task_id: parent_task.id,
      creative_id: @creative.id,
      trigger_event_payload: workflow_context
    )

    fail_called_with = nil
    fake_executor = Class.new do
      define_method(:fail_subtask!) do |child, error_message: nil|
        fail_called_with = { sub_task: child, error_message: error_message }
      end
    end.new

    delivered = false
    fake_adapter = Class.new do
      define_method(:initialize) { |agent:, context:, task: nil| }
      define_method(:deliver) { delivered = true; nil }
    end

    Collavre::Comments::WorkflowExecutor.stub :new, fake_executor do
      Collavre::AiAgent::ClaudeChannelAdapter.stub :new, ->(**kw) { fake_adapter.new(**kw) } do
        AiAgentJob.perform_now(sub_task)
      end
    end

    refute delivered, "adapter must not run for offline-resumed Claude Channel subtask"
    assert_equal "failed", sub_task.reload.status,
      "subtask must transition to failed so the parent workflow sees a terminal state"
    assert_not_nil fail_called_with,
      "Expected WorkflowExecutor#fail_subtask! to be invoked so the parent workflow fails"
    assert_equal sub_task.id, fail_called_with[:sub_task].id
    assert_match(/offline/i, fail_called_with[:error_message].to_s)
  end

  # A resumed Task takes the branch above the agent_id guard, so the assignment
  # was rechecked only at enqueue time. Comments::ActionExecutor re-enqueues an
  # approved tool call with perform_later(task) and no check at all, and the
  # pause between the two lasts as long as the human takes to approve — plenty
  # of room for the topic to be pinned to someone else.
  test "resumed task does not run when the topic was assigned to another agent while it waited" do
    topic = Topic.create!(creative: @creative, name: "resumed-reassigned", user: @owner)
    primary = User.create!(
      email: "resumed_primary@example.com", name: "Resumed Primary",
      password: "password", llm_vendor: "google", llm_model: "gemini-1.5-flash",
      searchable: true
    )
    task = Task.create!(
      name: "Response to comment_created",
      status: "pending_approval",
      trigger_event_name: "comment_created",
      trigger_event_payload: @context.merge("topic" => { "id" => topic.id }),
      agent: @agent,
      topic_id: topic.id,
      creative_id: @creative.id
    )

    # The pin lands after the task was enqueued for resumption.
    topic.set_primary_agent!(primary)

    replies_before = Comment.where(creative_id: @creative.id, user_id: @agent.id).count

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      AiAgentJob.perform_now(task)
    end

    assert_equal "cancelled", task.reload.status,
      "a resumed task the assignment now excludes must be cancelled, not left pending"
    assert_equal replies_before, Comment.where(creative_id: @creative.id, user_id: @agent.id).count,
      "the demoted agent must not reply in a topic that now belongs to another agent"
  end

  # Negative control: without it the test above would also pass if the guard
  # simply cancelled every resumed task.
  test "resumed task still runs when the assignment names its own agent" do
    topic = Topic.create!(creative: @creative, name: "resumed-still-mine", user: @owner)
    topic.set_primary_agent!(@agent)

    task = Task.create!(
      name: "Response to comment_created",
      status: "pending_approval",
      trigger_event_name: "comment_created",
      trigger_event_payload: @context.merge("topic" => { "id" => topic.id }),
      agent: @agent,
      topic_id: topic.id,
      creative_id: @creative.id
    )

    AiClient.stub :new, ->(**kwargs) { FakeAiClient.new } do
      AiAgentJob.perform_now(task)
    end

    assert_equal "done", task.reload.status,
      "the assigned agent's own resumed task must still run"
  end
end
