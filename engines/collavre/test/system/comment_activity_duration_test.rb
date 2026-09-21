# frozen_string_literal: true

require_relative "../application_system_test_case"

class CommentActivityDurationTest < ApplicationSystemTestCase
  setup do
    resize_window_to
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
      open_activity_log
      assert_selector ".activity-time", text: /ago\s*\(1m 23s\)/
      assert_no_selector ".activity-log-duration"
    end
    within("#comment_#{@reviewed.id}") do
      assert_no_selector ".comment-execution-time"
      open_activity_log
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
      open_activity_log
      assert_selector ".activity-name", text: "LLM"
      assert_no_selector ".activity-log-duration, .activity-execution-time"
    end
  end

  test "long activity names and timing fit a narrow dark panel" do
    @reply.activity_logs.first.update!(activity: "LongActivity" * 20)
    visit collavre.creatives_path(id: @creative.id)
    find("button[name='show-comments-btn'][data-creative-id='#{@creative.id}']").click
    assert_docked_comments_loaded
    within("#comment_#{@reply.id}") { open_activity_log }
    assert_selector "#comment_#{@reply.id} .activity-log-list"
    page.execute_script <<~JS
      document.body.classList.add('dark-mode');
      const list = document.querySelector('#comment_#{@reply.id} .activity-log-list');
      list.style.width = '240px';
    JS
    assert page.evaluate_script(<<~JS)
      (() => {
        const item = document.querySelector('#comment_#{@reply.id} .activity-log-item');
        const summary = item.querySelector('.activity-log-summary');
        const duration = item.querySelector('.activity-execution-time');
        return item.scrollWidth <= item.clientWidth &&
          getComputedStyle(summary).flexWrap === 'wrap' &&
          getComputedStyle(duration).whiteSpace === 'nowrap';
      })()
    JS
  end

  private

  def open_activity_log
    find(".comment-activity-log-block > details > summary").click
    # Keep timing assertions independent of the chat panel auto-scroll and lazy loading.
    frame = find("turbo-frame[id^='activity_log_details_']")
    frame.execute_script("this.loading = 'eager'")
    assert_selector "turbo-frame[complete] .activity-log-list"
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
