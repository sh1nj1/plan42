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

  [ false, true ].each do |with_logs|
    test "shows latest review duration after finalization with logs=#{with_logs}" do
      original_task = @task
      review_task = Collavre::Task.create!(name: "Review", agent: @user, status: "running")
      review_task.task_actions.create!(action_type: "start", status: "done", created_at: 30.seconds.ago)
      review_task.task_actions.create!(action_type: "completion", status: "done", created_at: 10.seconds.ago)
      review = @creative.comments.create!(user: @user, content: "Revise", quoted_comment: @comment)
      placeholder = @creative.comments.create!(user: @user, content: "Working", task: review_task)
      placeholder.activity_logs.create!(user: @user, activity: "Review LLM") if with_logs

      Collavre::AiAgent::ResponseFinalizer.new(
        task: review_task, agent: @user, original_comment: review,
        reply_comment: placeholder, response_content: "Revised answer"
      ).finalize
      review_task.update!(status: "done")
      get creative_comment_activity_log_path(@creative, @comment), params: { locale: :en }

      assert_response :success
      assert_select ".activity-log-duration", text: "Execution time: 20s"
      assert_select ".activity-name", text: "Review LLM", count: with_logs ? 1 : 0
      assert_equal 83, Collavre::TaskExecutionTime.seconds(original_task)
      assert_not Collavre::Comment.exists?(placeholder.id)
    end
  end

  test "rejects users without creative read permission" do
    sign_in_as(users(:two), password: "password")
    get creative_comment_activity_log_path(@creative, @comment)

    assert_response :forbidden
  end
end
