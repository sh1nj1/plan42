# frozen_string_literal: true

require "test_helper"

class Comments::ActivityLogsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(locale: :en)
    @creative = Collavre::Creative.create!(user: @user, description: "Timing")
    @task = Collavre::Task.create!(name: "Timed task", agent: @user, status: "done")
    @comment = Collavre::Comment.create!(user: @user, creative: @creative, task: @task, content: "Reply")
    started_at = Time.current - 100
    @task.task_actions.create!(action_type: "start", status: "done", created_at: started_at)
    @task.task_actions.create!(action_type: "completion", status: "done", created_at: started_at + 83)
    sign_in_as(@user, password: "password")
  end

  test "shows execution time without activity logs" do
    get creative_comment_activity_log_path(@creative, @comment), params: { locale: :en }

    assert_response :success
    assert_select ".activity-log-duration", text: "Execution time: 1m 23s"
    assert_select ".activity-log-empty", text: "No activity logs available."
  end

  test "shows Korean time and preserves activity log details" do
    @user.update!(locale: :ko)
    @comment.activity_logs.create!(activity: "LLM", log: { response: "<script>alert(1)</script>" })
    get creative_comment_activity_log_path(@creative, @comment), params: { locale: :ko }

    assert_response :success
    assert_select ".activity-log-duration", text: "수행 시간: 1분 23초"
    assert_select ".activity-name", text: "LLM"
    assert_select ".activity-time", text: /전$/
    assert_select ".activity-log-yaml", text: /<script>alert\(1\)<\/script>/
    assert_select ".activity-log-yaml script", count: 0
  end

  test "does not show execution time for comments without a task" do
    @comment.update!(task: nil)
    get creative_comment_activity_log_path(@creative, @comment), params: { locale: :en }

    assert_response :success
    assert_select ".activity-log-duration", count: 0
  end

  test "shows unavailable when completion evidence is missing" do
    @user.update!(locale: :ko)
    @task.task_actions.where(action_type: "completion").delete_all
    get creative_comment_activity_log_path(@creative, @comment), params: { locale: :ko }

    assert_response :success
    assert_select ".activity-log-duration", text: "수행 시간: 측정 불가"
  end

  test "rejects users without creative read permission" do
    sign_in_as(users(:two), password: "password")
    get creative_comment_activity_log_path(@creative, @comment)

    assert_response :forbidden
  end
end
