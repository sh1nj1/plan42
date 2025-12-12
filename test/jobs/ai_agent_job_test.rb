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
    assert_equal @agent, task.agent
    assert_equal "test_event", task.trigger_event_name
    assert_equal "done", task.status

    # Verify Task Actions
    assert_equal 4, task.task_actions.count
    assert_equal [ "start", "prompt_generated", "completion", "reply_created" ], task.task_actions.pluck(:action_type)
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

    # Verify no new comment created
    assert_equal 1, @creative.comments.count # Only the initial comment
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

    user_msg_idx = messages.index { |m| m[:role] == "user" && m[:parts][0][:text] == "Previous user message" }
    agent_msg_idx = messages.index { |m| m[:role] == "model" && m[:parts][0][:text] == "Previous agent message" }
    current_msg_idx = messages.index { |m| m[:role] == "user" && m[:parts][0][:text] == "Hello" }

    assert user_msg_idx, "Previous user message not found"
    assert agent_msg_idx, "Previous agent message not found"
    assert current_msg_idx, "Current message not found"

    assert user_msg_idx < agent_msg_idx
    assert agent_msg_idx < current_msg_idx
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

    # Should include "Message 59" (most recent)
    assert_includes message_texts, "Message 59"

    # Should NOT include "Message 0" (oldest)
    assert_not_includes message_texts, "Message 0"

    # Verify we have roughly 50 history items + creative context + trigger payload
    # Exact count depends on implementation details, but should be around 52-53
    assert messages.count > 40
    assert messages.count < 60
  end
end
