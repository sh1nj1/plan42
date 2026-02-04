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

  test "creates placeholder and streams content into it" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Chunk 1 "
      yield "Chunk 2"
    end

    initial_comment_count = @creative.comments.count

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # One new comment: the placeholder that was updated with final content
    assert_equal initial_comment_count + 1, @creative.comments.count

    reply = @creative.comments.where(user: @agent).order(:created_at).last
    assert_equal "Chunk 1 Chunk 2", reply.content
    assert_nil reply.topic_id # trigger comment has no topic

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

    thinking_idx = statuses.index("thinking")
    idle_idx = statuses.rindex("idle")
    assert thinking_idx < idle_idx
  end

  test "reassociates activity logs from trigger comment to reply comment" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "AI Response"
    end

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

    initial_comment_count = @creative.comments.count

    AiClient.stub :new, mock_client do
      AiAgentService.new(@task).call
    end

    # Placeholder created then destroyed → net zero
    assert_equal initial_comment_count, @creative.comments.count
    assert_not @creative.comments.exists?(content: Collavre::Comment::STREAMING_PLACEHOLDER_CONTENT)
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

    original_interval = AiAgentService::CANCEL_CHECK_INTERVAL
    AiAgentService.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    AiAgentService.const_set(:CANCEL_CHECK_INTERVAL, 0)

    assert_raises(Collavre::CancelledError) do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    AiAgentService.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    AiAgentService.const_set(:CANCEL_CHECK_INTERVAL, original_interval)

    # Placeholder should contain partial content
    reply = @creative.comments.where(user: @agent).order(:created_at).last
    assert reply.content.start_with?("Partial content")
    assert @task.task_actions.exists?(action_type: "cancelled")
  end
end
