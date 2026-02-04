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

  test "streams response and creates final comment without placeholder" do
    # Mock AiClient to simulate streaming
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Chunk 1 "
      yield "Chunk 2"
    end

    initial_comment_count = @creative.comments.count

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # Only one new comment should be created (the final reply, no placeholder)
    assert_equal initial_comment_count + 1, @creative.comments.count

    # Find the reply comment
    reply = @creative.comments.order(:created_at).last

    assert_not_equal @comment.id, reply.id
    assert_equal @agent.id, reply.user.id
    assert_equal "Chunk 1 Chunk 2", reply.content

    # Verify no "..." placeholder exists
    assert_not @creative.comments.exists?(content: "...")

    # Verify actions were logged
    assert @task.task_actions.exists?(action_type: "start")
    assert @task.task_actions.exists?(action_type: "prompt_generated")
    assert @task.task_actions.exists?(action_type: "completion")
    assert @task.task_actions.exists?(action_type: "reply_created")
  end

  test "broadcasts agent status during execution" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Response"
    end

    broadcasts = []
    creative_id = @creative.effective_origin.id

    # Capture ActionCable broadcasts
    ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
      # Also stub Turbo broadcasts to avoid errors
      Turbo::StreamsChannel.stub :broadcast_append_to, nil do
        Turbo::StreamsChannel.stub :broadcast_replace_to, nil do
          Turbo::StreamsChannel.stub :broadcast_remove_to, nil do
            AiClient.stub :new, mock_client do
              AiAgentService.new(@task).call
            end
          end
        end
      end
    end

    presence_broadcasts = broadcasts.select { |b| b[:channel] == "comments_presence:#{creative_id}" }
    agent_statuses = presence_broadcasts.select { |b| b[:data][:agent_status].present? }

    # Should have thinking and idle broadcasts at minimum
    statuses = agent_statuses.map { |b| b[:data][:agent_status][:status] }
    assert_includes statuses, "thinking"
    assert_includes statuses, "idle"

    # thinking should come before idle
    thinking_idx = statuses.index("thinking")
    idle_idx = statuses.rindex("idle")
    assert thinking_idx < idle_idx
  end

  test "does not create comment when response is empty" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      # No yield - empty response
    end

    initial_comment_count = @creative.comments.count

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # No new comment should be created
    assert_equal initial_comment_count, @creative.comments.count

    # Verify no "..." placeholder exists
    assert_not @creative.comments.exists?(content: "...")
  end
end
