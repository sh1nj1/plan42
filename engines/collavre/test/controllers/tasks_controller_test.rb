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
end
