# frozen_string_literal: true

require "test_helper"

class TasksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @creative = Collavre::Creative.create!(user: @user, description: "Test Creative")
    @agent = User.create!(
      email: "cancel_task_agent@example.com",
      name: "Cancel Agent",
      password: "password",
      llm_vendor: "google",
      llm_model: "gemini-2.0-flash",
      routing_expression: "true",
      searchable: true
    )
    @task = Collavre::Task.create!(
      name: "Response to comment_created",
      status: "running",
      trigger_event_name: "comment_created",
      trigger_event_payload: {
        "comment" => { "id" => 1, "content" => "Hello" },
        "creative" => { "id" => @creative.id }
      },
      agent: @agent
    )
  end

  test "cancel sets task status to cancelled" do
    sign_in_as(@user, password: "password")
    post cancel_task_path(@task)
    assert_response :ok
    assert_equal "cancelled", @task.reload.status
  end

  test "cancel returns forbidden for user without permission" do
    other_user = User.create!(
      email: "no_perm_cancel@example.com",
      name: "No Perm",
      password: "password"
    )
    sign_in_as(other_user, password: "password")

    post cancel_task_path(@task)
    assert_response :forbidden
    assert_equal "running", @task.reload.status
  end

  test "cancel returns unprocessable_entity for done task" do
    sign_in_as(@user, password: "password")
    @task.update!(status: "done")

    post cancel_task_path(@task)
    assert_response :unprocessable_entity
    assert_equal "done", @task.reload.status
  end

  test "cancel works for pending task" do
    sign_in_as(@user, password: "password")
    @task.update!(status: "pending")

    post cancel_task_path(@task)
    assert_response :ok
    assert_equal "cancelled", @task.reload.status
  end

  test "cancel works for queued task" do
    sign_in_as(@user, password: "password")
    @task.update!(status: "queued")

    post cancel_task_path(@task)
    assert_response :ok
    assert_equal "cancelled", @task.reload.status
  end

  test "cancel returns unprocessable_entity for already cancelled task" do
    sign_in_as(@user, password: "password")
    @task.update!(status: "cancelled")

    post cancel_task_path(@task)
    assert_response :unprocessable_entity
  end

  test "cancel cancels delegated task and releases agent slot" do
    sign_in_as(@user, password: "password")
    @task.update!(status: "delegated", topic_id: 12_345)

    tracker = Minitest::Mock.new
    tracker.expect(:release!, true, [ @task.id ])

    Collavre::Orchestration::ResourceTracker.stub(:for, ->(agent) { agent == @agent ? tracker : nil }) do
      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(_t, _c) { nil }) do
        post cancel_task_path(@task)
      end
    end

    assert_response :ok
    assert_equal "cancelled", @task.reload.status
    tracker.verify
  end

  test "cancel releases agent slot and drains queue for pending_approval task" do
    sign_in_as(@user, password: "password")
    # A pending_approval blocker still holds the topic/agent slot: AiAgentJob
    # already returned via ApprovalPendingError with should_release = false, so
    # no live worker will run the ensure-block release. Cancelling it must free
    # the slot and drain the topic queue, or the stop button leaves the queued
    # waiter (and agent capacity) stuck until some later recovery path runs.
    @task.update!(status: "pending_approval", topic_id: 12_345, creative_id: @creative.id)

    tracker = Minitest::Mock.new
    tracker.expect(:release!, true, [ @task.id ])

    dequeued = []
    Collavre::Orchestration::ResourceTracker.stub(:for, ->(agent) { agent == @agent ? tracker : nil }) do
      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(t, c) { dequeued << [ t, c ] }) do
        post cancel_task_path(@task)
      end
    end

    assert_response :ok
    assert_equal "cancelled", @task.reload.status
    tracker.verify
    assert_equal [ [ 12_345, @creative.id ] ], dequeued,
      "Expected the topic queue to be drained so the queued waiter is promoted"
  end

  test "cancel releases agent slot and drains queue for pending task" do
    sign_in_as(@user, password: "password")
    # A pending task counts against the topic slot (occupying_topic_slot) — e.g. a
    # waiter that dequeue_next_for_topic promoted queued -> pending before its job
    # starts. Cancelling it never reaches AiAgentJob's ensure-block drain: the job
    # early-returns at the top on "cancelled". So the controller must drain here,
    # or the next queued waiter stays blocked until stuck recovery.
    @task.update!(status: "pending", topic_id: 12_345, creative_id: @creative.id)

    tracker = Minitest::Mock.new
    tracker.expect(:release!, true, [ @task.id ])

    dequeued = []
    Collavre::Orchestration::ResourceTracker.stub(:for, ->(agent) { agent == @agent ? tracker : nil }) do
      Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(t, c) { dequeued << [ t, c ] }) do
        post cancel_task_path(@task)
      end
    end

    assert_response :ok
    assert_equal "cancelled", @task.reload.status
    tracker.verify
    assert_equal [ [ 12_345, @creative.id ] ], dequeued,
      "Expected the topic queue to be drained so the next queued waiter is promoted"
  end

  test "cancel takes down the cancelled waiter's own per-deferral notice" do
    # The third door a waiter leaves the queue through without being promoted:
    # the user's own stop button. Its "task" notice names this task, so once the
    # task is cancelled the notice is a waiting line whose stop button selects a
    # task no longer queued and therefore cancels nothing. A sibling still parked
    # keeps the drained sweep from ever collecting it.
    sign_in_as(@user, password: "password")
    topic = Collavre::Topic.create!(name: "Cancel topic", creative: @creative, user: @user)
    @task.update!(status: "queued", topic_id: topic.id, creative_id: @creative.id)

    sibling = Collavre::Task.create!(
      name: "Sibling waiter", status: "queued",
      trigger_event_name: "comment_created",
      trigger_event_payload: { "creative" => { "id" => @creative.id } },
      agent: @agent, topic_id: topic.id, creative_id: @creative.id
    )

    own_notice = @creative.comments.create!(
      content: "⏳ waiting", topic_id: topic.id, private: false, skip_default_user: true,
      topic_concurrency_defer: true,
      waiting_notice_scope: Collavre::Comment::WAITING_NOTICE_TASK,
      waiting_notice_task_id: @task.id
    )
    sibling_notice = @creative.comments.create!(
      content: "⏳ waiting", topic_id: topic.id, private: false, skip_default_user: true,
      topic_concurrency_defer: true,
      waiting_notice_scope: Collavre::Comment::WAITING_NOTICE_TASK,
      waiting_notice_task_id: sibling.id
    )

    post cancel_task_path(@task)

    assert_response :ok
    assert_equal "cancelled", @task.reload.status
    assert_nil Collavre::Comment.find_by(id: own_notice.id),
      "Expected the cancelled waiter's own notice to come down with it"
    # Invariant rather than "this row is gone", so it keeps meaning something
    # once the row is gone: no "task" notice names a task that left the queue.
    stranded = Collavre::Comment.where(waiting_notice_scope: Collavre::Comment::WAITING_NOTICE_TASK)
                                .where.not(waiting_notice_task_id: nil)
                                .select { |c| Collavre::Task.find_by(id: c.waiting_notice_task_id)&.status != "queued" }
    assert_empty stranded, "Expected no task-scoped notice naming a task that is no longer queued"
    # Control: the sibling is still queued, so its notice — and its stop button — stays.
    assert Collavre::Comment.exists?(id: sibling_notice.id),
      "Expected a still-queued waiter's notice to be untouched by another waiter's cancellation"
    assert_equal "queued", sibling.reload.status
  end

  test "cancel takes down a shared notice its last waiter leaves behind" do
    # Same door, the other kind of notice. With coalescing on the waiter has no
    # notice of its own — the topic's single shared one speaks for it — so
    # remove_waiter_notices! finds nothing to take down and the "⏳" line stays
    # on screen with a stop button that now selects nothing.
    sign_in_as(@user, password: "password")
    topic = Collavre::Topic.create!(name: "Cancel topic", creative: @creative, user: @user)
    @task.update!(status: "queued", topic_id: topic.id, creative_id: @creative.id)

    shared = @creative.comments.create!(
      content: "⏳ waiting", topic_id: topic.id, private: false, skip_default_user: true,
      topic_concurrency_defer: true,
      waiting_notice_scope: Collavre::Comment::WAITING_NOTICE_TOPIC
    )

    post cancel_task_path(@task)

    assert_response :ok
    assert_equal "cancelled", @task.reload.status
    assert_nil Collavre::Comment.find_by(id: shared.id),
      "Expected the shared notice to come down once nothing it speaks for is queued"
  end

  test "cancel keeps a shared notice that still speaks for a queued waiter" do
    # The control: "take the shared notice down whenever a waiter is cancelled"
    # would pass the test above while disarming a wait that is still real.
    sign_in_as(@user, password: "password")
    topic = Collavre::Topic.create!(name: "Cancel topic", creative: @creative, user: @user)
    @task.update!(status: "queued", topic_id: topic.id, creative_id: @creative.id)

    sibling = Collavre::Task.create!(
      name: "Sibling waiter", status: "queued",
      trigger_event_name: "comment_created",
      trigger_event_payload: { "creative" => { "id" => @creative.id } },
      agent: @agent, topic_id: topic.id, creative_id: @creative.id
    )
    shared = @creative.comments.create!(
      content: "⏳ waiting", topic_id: topic.id, private: false, skip_default_user: true,
      topic_concurrency_defer: true,
      waiting_notice_scope: Collavre::Comment::WAITING_NOTICE_TOPIC
    )

    post cancel_task_path(@task)

    assert_response :ok
    assert_equal "queued", sibling.reload.status
    assert Collavre::Comment.exists?(id: shared.id),
      "Expected the shared notice to stay up for the waiter it still speaks for"
  end
end
