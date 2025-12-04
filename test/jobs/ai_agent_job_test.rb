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

    def initialize(vendor:, model:, system_prompt:, llm_api_key:)
      @captured_system_prompt = system_prompt
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
end
