# frozen_string_literal: true

require_relative "../application_system_test_case"

class CommentActivityDurationTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(email: "activity-duration@example.com", password: SystemHelpers::PASSWORD,
                         name: "Timing User", email_verified_at: Time.current, locale: :en,
                         notifications_enabled: false)
    @creative = Creative.create!(description: "Task timing", user: @user)
    task = Collavre::Task.create!(name: "Timed task", agent: @user, status: "done")
    @reply = Comment.create!(creative: @creative, user: @user, task: task, content: "Timed response")
    @reply.activity_logs.create!(activity: "LLM", log: { result: "ok" })
    @plain = Comment.create!(creative: @creative, user: @user, content: "Plain response")
    @logged = Comment.create!(creative: @creative, user: @user, content: "Logged response")
    @logged.activity_logs.create!(activity: "LLM", log: { result: "ok" })
    started_at = Time.current - 100
    task.task_actions.create!(action_type: "start", status: "done", created_at: started_at)
    task.task_actions.create!(action_type: "completion", status: "done", created_at: started_at + 83)
    historical_task = Collavre::Task.create!(name: "Historical delegation", agent: @user, status: "done")
    @historical = Comment.create!(creative: @creative, user: @user, task: historical_task, content: "Old response")
    create_reviewed_reply
    sign_in_via_ui(@user)
  end

  test "execution time appears only beside the activity timestamp" do
    visit collavre.creatives_path(id: @creative.id)
    find("button[name='show-comments-btn'][data-creative-id='#{@creative.id}']", wait: 10).click

    assert_docked_comments_loaded

    within("#comment_#{@reply.id}") do
      assert_no_selector ".comment-execution-time"
      assert_selector "time[datetime]"
      open_activity_logs
      assert_selector ".activity-time", text: /ago\s*\(1m 23s\)/
      assert_no_selector ".activity-log-duration"
    end
    within("#comment_#{@reviewed.id}") do
      assert_no_selector ".comment-execution-time"
      open_activity_logs
      assert_selector ".activity-time .activity-execution-time", text: "(20s)"
    end
    within("#comment_#{@historical.id}") do
      assert_no_selector ".comment-execution-time"
      assert_no_selector ".comment-activity-log-block"
    end
    within("#comment_#{@plain.id}") do
      assert_no_selector ".comment-execution-time"
      assert_no_selector ".comment-activity-log-block"
    end
    within("#comment_#{@logged.id}") do
      open_activity_logs
      assert_selector ".activity-name", text: "LLM"
      assert_no_selector ".activity-log-duration, .activity-execution-time"
    end
  end

  private

  def open_activity_logs
    find(".comment-activity-log-block summary").click
    # Turbo's lazy frame below the summary may still be outside the chat's
    # scroll viewport. Bring it into view so its request actually starts.
    frame = find("turbo-frame[id^='activity_log_details_']", visible: :all)
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", frame)
    assert_selector ".activity-log-list"
  end

  def create_reviewed_reply
    @reviewed = Comment.create!(creative: @creative, user: @user, content: "Draft")
    review = Comment.create!(creative: @creative, user: @user, content: "Revise", quoted_comment: @reviewed)
    task = Collavre::Task.create!(name: "Review task", agent: @user, status: "running")
    reply = Comment.create!(creative: @creative, user: @user, task: task, content: "Working")
    reply.activity_logs.create!(user: @user, activity: "Review LLM")
    started_at = 30.seconds.ago
    task.task_actions.create!(action_type: "start", status: "done", created_at: started_at)
    task.task_actions.create!(action_type: "completion", status: "done", created_at: started_at + 20)
    Collavre::AiAgent::ResponseFinalizer.new(
      task: task, agent: @user, original_comment: review, reply_comment: reply,
      response_content: "Revised response"
    ).finalize
    task.update!(status: "done")
  end
end
