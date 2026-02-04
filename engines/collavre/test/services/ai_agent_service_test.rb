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

  test "broadcasts agent status with content during execution" do
    mock_client = Minitest::Mock.new

    def mock_client.chat(messages, tools: [])
      yield "Response"
    end

    broadcasts = []
    creative_id = @creative.effective_origin.id

    # Capture ActionCable broadcasts (streaming content is now sent via agent_status, no Turbo Streams)
    ActionCable.server.stub :broadcast, ->(channel, data) { broadcasts << { channel: channel, data: data } } do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    presence_broadcasts = broadcasts.select { |b| b[:channel] == "comments_presence:#{creative_id}" }
    agent_statuses = presence_broadcasts.select { |b| b[:data][:agent_status].present? }

    # Should have thinking, streaming (with content), and idle broadcasts
    statuses = agent_statuses.map { |b| b[:data][:agent_status][:status] }
    assert_includes statuses, "thinking"
    assert_includes statuses, "idle"

    # thinking should come before idle
    thinking_idx = statuses.index("thinking")
    idle_idx = statuses.rindex("idle")
    assert thinking_idx < idle_idx

    # Streaming broadcasts should include content
    streaming_with_content = agent_statuses.select { |b| b[:data][:agent_status][:content].present? }
    assert streaming_with_content.any?, "Expected at least one broadcast with content"
    assert_equal "Response", streaming_with_content.last[:data][:agent_status][:content]
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

  test "saves partial response as comment when cancelled" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |messages, tools: [], &block|
      block.call("Partial ")
      block.call("content")
      # Simulate cancellation by changing task status mid-stream
      Task.find(task_id).update!(status: "cancelled")
      # Advance time past CANCEL_CHECK_INTERVAL so check_cancelled! fires
      sleep(0) # yield control
      block.call(" more") # This chunk triggers check_cancelled! which raises
    end

    initial_comment_count = @creative.comments.count

    # Stub CANCEL_CHECK_INTERVAL to 0 so cancellation is detected immediately
    original_interval = AiAgentService::CANCEL_CHECK_INTERVAL
    AiAgentService.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    AiAgentService.const_set(:CANCEL_CHECK_INTERVAL, 0)

    assert_raises(Collavre::CancelledError) do
      AiClient.stub :new, mock_client do
        AiAgentService.new(@task).call
      end
    end

    # Restore original interval
    AiAgentService.send(:remove_const, :CANCEL_CHECK_INTERVAL)
    AiAgentService.const_set(:CANCEL_CHECK_INTERVAL, original_interval)

    # A partial comment should have been saved
    assert_equal initial_comment_count + 1, @creative.comments.count

    reply = @creative.comments.where(user: @agent).order(:created_at).last
    # Content should contain at least the chunks before cancellation
    assert reply.content.start_with?("Partial content")

    # Verify cancel action was logged
    assert @task.task_actions.exists?(action_type: "cancelled")
    assert @task.task_actions.exists?(action_type: "reply_created")
  end

  test "does not create comment when cancelled with empty response" do
    task_id = @task.id
    mock_client = Object.new
    mock_client.define_singleton_method(:chat) do |messages, tools: [], &block|
      # Cancel immediately before any content
      Task.find(task_id).update!(status: "cancelled")
      block.call("") # Empty content, triggers check_cancelled!
    end

    initial_comment_count = @creative.comments.count

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

    # No comment created since response was empty
    assert_equal initial_comment_count, @creative.comments.count
  end

  test "broadcasts topic_id in agent status" do
    topic = Topic.create!(creative: @creative, name: "Test Topic", user: @user)
    @comment.update!(topic_id: topic.id)

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

    # All broadcasts should include topic_id
    agent_statuses.each do |b|
      assert_equal topic.id, b[:data][:agent_status][:topic_id],
        "Expected topic_id #{topic.id} in agent_status broadcast, got #{b[:data][:agent_status][:topic_id]}"
    end

    # Reply comment should also be in the correct topic
    reply = @creative.comments.where(user: @agent).order(:created_at).last
    assert_equal topic.id, reply.topic_id
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
