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
end
