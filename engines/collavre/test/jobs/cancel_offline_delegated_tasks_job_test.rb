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

  test "no-op when a sibling session still holds a presence row (shared agent online)" do
    topic = Topic.create!(creative: @creative, name: "cc-sibling-topic", user: @owner)
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

    # The dropped session cleared routing on its way out, but a concurrent
    # sibling session sharing this agent is still subscribed — its presence row
    # proves the agent is online and its delegated work must not be cancelled.
    Collavre::AgentSubscription.create!(agent_id: @claude_agent.id, token: "sibling-still-here")

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "expected-token-value")

    assert_equal "delegated", delegated_task.reload.status,
      "delegated work must survive while a sibling session is still subscribed"
  end

  test "cancels delegated work when the only presence row is stale (crash-orphaned)" do
    topic = Topic.create!(creative: @creative, name: "cc-stale-row-topic", user: @owner)
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

    # A crash-orphaned row from a process that died without unsubscribing. It is
    # NOT proof the agent is online — the job must ignore stale rows (and reap
    # them) so offline delegated work is still cancelled.
    stale = Collavre::AgentSubscription.create!(agent_id: @claude_agent.id, token: "crashed-process")
    stale.update_column(:last_seen_at, (Collavre::AgentSubscription::STALE_AFTER + 1.minute).ago)

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "expected-token-value")

    assert_equal "cancelled", delegated_task.reload.status,
      "a stale presence row must not keep delegated work alive"
    refute Collavre::AgentSubscription.exists?(id: stale.id),
      "the job should reap the crash-orphaned row"
  end

  test "session-scoped: cancels the dropped session's session-topic delegated task despite a live sibling" do
    # Codex P2: a live sibling keeps routing_expression on, so the agent-wide
    # rechecks would no-op — but the dropped session's own session topic is
    # private to it and no sibling will /reply. The session-scoped invocation
    # targets only that topic's delegated work.
    @claude_agent.update_column(:routing_expression, "true")
    Collavre::AgentSubscription.create!(
      agent_id: @claude_agent.id, token: "sibling", session_id: "sess-other"
    )

    session_topic = Topic.create!(
      creative: @creative, name: "cc-session-topic", user: @owner,
      primary_agent_id: @claude_agent.id, session_id: "sess-drop"
    )
    task = Task.create!(
      name: "Delegated on session topic", status: "delegated",
      agent: @claude_agent, creative_id: @creative.id, topic_id: session_topic.id
    )

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "tok", "sess-drop")

    assert_equal "cancelled", task.reload.status,
      "the dropped session's own session-topic work must be cancelled"
  end

  test "session-scoped: no-op when the same session reconnected within the grace window" do
    Collavre::AgentSubscription.create!(
      agent_id: @claude_agent.id, token: "reconnected", session_id: "sess-drop"
    )
    session_topic = Topic.create!(
      creative: @creative, name: "cc-reconnect-topic", user: @owner,
      primary_agent_id: @claude_agent.id, session_id: "sess-drop"
    )
    task = Task.create!(
      name: "Delegated on session topic", status: "delegated",
      agent: @claude_agent, creative_id: @creative.id, topic_id: session_topic.id
    )

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "tok", "sess-drop")

    assert_equal "delegated", task.reload.status,
      "a reconnected session (live row with the same session_id) keeps its work"
  end

  test "session-scoped: leaves shared work-topic tasks for a live sibling to claim" do
    # A delegated task on a DIFFERENT topic is fan-out work any live session can
    # /reply to — the dropped session's session-scoped cleanup must not touch it.
    Collavre::AgentSubscription.create!(
      agent_id: @claude_agent.id, token: "sibling", session_id: "sess-other"
    )
    Topic.create!(
      creative: @creative, name: "cc-own-session-topic", user: @owner,
      primary_agent_id: @claude_agent.id, session_id: "sess-drop"
    )
    work_topic = Topic.create!(creative: @creative, name: "cc-work-topic", user: @owner)
    work_task = Task.create!(
      name: "Shared work-topic task", status: "delegated",
      agent: @claude_agent, creative_id: @creative.id, topic_id: work_topic.id
    )

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "tok", "sess-drop")

    assert_equal "delegated", work_task.reload.status,
      "work-topic tasks belong to the fan-out pool and must survive a session-scoped cancel"
  end

  test "session-scoped: also cancels queued work on the dropped session topic" do
    # Codex P2: cancelling only the delegated task drains the topic queue and
    # promotes the queued task into this now-clientless session topic, which no
    # sibling will /reply to. The queued task must be cancelled too, before the
    # delegated cancel triggers dequeue_next_for_topic.
    @claude_agent.update_column(:routing_expression, "true")
    Collavre::AgentSubscription.create!(
      agent_id: @claude_agent.id, token: "sibling", session_id: "sess-other"
    )

    session_topic = Topic.create!(
      creative: @creative, name: "cc-queued-session-topic", user: @owner,
      primary_agent_id: @claude_agent.id, session_id: "sess-drop"
    )
    delegated_task = Task.create!(
      name: "Delegated on session topic", status: "delegated",
      agent: @claude_agent, creative_id: @creative.id, topic_id: session_topic.id
    )
    queued_task = Task.create!(
      name: "Queued on session topic", status: "queued",
      agent: @claude_agent, creative_id: @creative.id, topic_id: session_topic.id
    )

    Collavre::CancelOfflineDelegatedTasksJob.perform_now(@claude_agent.id, "tok", "sess-drop")

    assert_equal "cancelled", delegated_task.reload.status,
      "the dropped session's delegated work must be cancelled"
    assert_equal "cancelled", queued_task.reload.status,
      "queued work on the dropped session topic must be cancelled, not promoted into a clientless topic"
  end
end
