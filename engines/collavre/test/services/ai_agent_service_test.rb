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
        "creative" => { "id" => @creative.id }
      },
      agent: @agent
    )
  end

  test "steams response to a comment" do
    # Mock AiClient to simulate streaming
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Chunk 1 "
      yield "Chunk 2"
    end

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # Find the reply comment
    reply = @creative.comments.order(:created_at).last

    assert_not_equal @comment.id, reply.id
    assert_equal @agent.id, reply.user.id
    assert_equal "Chunk 1 Chunk 2", reply.content

    # Verify actions were logged
    assert @task.task_actions.exists?(action_type: "start")
    assert @task.task_actions.exists?(action_type: "prompt_generated")
    assert @task.task_actions.exists?(action_type: "completion")
    assert @task.task_actions.exists?(action_type: "reply_created")
  end
end
