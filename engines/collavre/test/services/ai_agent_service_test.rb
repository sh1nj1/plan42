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

  test "reassociates activity logs from trigger comment to reply comment" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "AI Response"
    end

    # Create an activity log on the trigger comment (simulating what AiClient does via RubyLlmInteractionLogger)
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

    # Activity log should now be on the reply comment, not the trigger comment
    assert_equal reply.id, activity_log.comment_id
    assert_not_equal @comment.id, activity_log.comment_id

    # Trigger comment should have no agent activity logs
    assert_equal 0, ActivityLog.where(comment: @comment, user: @agent).count

    # Reply comment should have the activity log
    assert_equal 1, reply.activity_logs.count
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
