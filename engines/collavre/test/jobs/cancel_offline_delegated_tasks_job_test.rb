require "test_helper"

class CancelOfflineDelegatedTasksJobTest < ActiveJob::TestCase
  setup do
    @owner = users(:one)
    @creative = Creative.create!(user: @owner, description: "CancelOfflineDelegatedTasksJob Test")
    @comment = Comment.create!(creative: @creative, user: @owner, content: "Hello")

    @claude_agent = User.create!(
      email: "cc-offline-cancel-agent@agent.collavre.local",
      name: "Claude Offline Cancel Agent",
      password: SecureRandom.hex(32),
      llm_vendor: "anthropic",
      llm_model: "claude-code",
      # offline state — routing_expression nil, expected_token captured
      routing_expression: nil,
      routing_subscription_token: nil,
      created_by_id: @owner.id,
      searchable: false
    )
  end

  test "cancels delegated tasks when agent remains offline through grace window" do
    topic = Topic.create!(creative: @creative, name: "cc-offline-topic", user: @owner)
    delegated_task = Task.create!(
      name: "Delegated task",
      status: "delegated",
      agent: @claude_agent,
      creative_id: @creative.id,
      topic_id: topic.id,
      trigger_event_payload: {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => topic.id },
        "comment" => { "id" => @comment.id }
      }
    )

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "expected-token-value")

    assert_equal "cancelled", delegated_task.reload.status
  end

  test "no-op when agent came back online (routing_expression restored)" do
    topic = Topic.create!(creative: @creative, name: "cc-online-topic", user: @owner)
    delegated_task = Task.create!(
      name: "Delegated task",
      status: "delegated",
      agent: @claude_agent,
      creative_id: @creative.id,
      topic_id: topic.id,
      trigger_event_payload: {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => topic.id }
      }
    )

    # Reconnect-grace path: the same MCP session resubscribed during the grace
    # window and restored routing_expression.
    @claude_agent.update_column(:routing_expression, "true")
    @claude_agent.update_column(:routing_subscription_token, "expected-token-value")

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "expected-token-value")

    assert_equal "delegated", delegated_task.reload.status, "Task should not be cancelled when agent is back online"
  end

  test "no-op when a different subscription has taken over (token rotated)" do
    topic = Topic.create!(creative: @creative, name: "cc-rotated-topic", user: @owner)
    delegated_task = Task.create!(
      name: "Delegated task",
      status: "delegated",
      agent: @claude_agent,
      creative_id: @creative.id,
      topic_id: topic.id,
      trigger_event_payload: {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => topic.id }
      }
    )

    # A NEW subscription took over — different process, new token. The new
    # session's lifecycle owns cancellation of its own delegated work; this
    # stale grace job must not double-cancel.
    @claude_agent.update_column(:routing_subscription_token, "new-different-token")

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "old-expected-token")

    assert_equal "delegated", delegated_task.reload.status, "Task should not be cancelled when a different session has taken over"
  end

  test "fails parent workflow when cancelling a delegated subtask" do
    parent_task = Task.create!(
      name: "Workflow Parent",
      status: "running",
      agent: @owner,
      creative_id: @creative.id
    )

    sub_task = Task.create!(
      name: "Claude subtask",
      status: "delegated",
      agent: @claude_agent,
      parent_task_id: parent_task.id,
      creative_id: @creative.id
    )

    fail_called_with = nil
    fake_executor = Class.new do
      define_method(:fail_subtask!) do |child, error_message: nil|
        fail_called_with = { sub_task: child, error_message: error_message }
      end
    end.new

    Collavre::Comments::WorkflowExecutor.stub :new, fake_executor do
      Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "expected-token-value")
    end

    assert_equal "cancelled", sub_task.reload.status
    assert_not_nil fail_called_with, "Expected WorkflowExecutor#fail_subtask! to be invoked for workflow subtasks"
    assert_equal sub_task.id, fail_called_with[:sub_task].id
    assert_match(/connection/i, fail_called_with[:error_message].to_s)
  end
end
