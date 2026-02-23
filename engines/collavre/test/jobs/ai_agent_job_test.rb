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

    def initialize(vendor:, model:, system_prompt:, llm_api_key:, context: {})
      @captured_system_prompt = system_prompt
      @captured_context = context
    end

    def chat(contents, tools: [], &block)
      block.call("AI Response") if block
      "AI Response"
    end
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
    attr_reader :captured_messages

    def initialize(*args); end

    def chat(messages, tools: [], &block)
      @captured_messages = messages
      block.call("AI Response") if block
      "AI Response"
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
    end

    # Temporarily set cancel check interval to 0 so it checks on every chunk
    original_interval = AiAgentService::CANCEL_CHECK_INTERVAL
    AiAgentService.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    AiAgentService.const_set(:CANCEL_CHECK_INTERVAL, 0)

    AiClient.stub :new, cancelling_client.new do
      AiAgentJob.perform_now(task)
    end

    assert_equal "cancelled", task.reload.status
    assert_includes task.task_actions.pluck(:action_type), "cancelled"
  ensure
    AiAgentService.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    AiAgentService.const_set(:CANCEL_CHECK_INTERVAL, original_interval)
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
end
