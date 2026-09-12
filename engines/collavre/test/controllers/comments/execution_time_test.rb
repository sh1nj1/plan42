# frozen_string_literal: true

require "test_helper"

class Comments::ExecutionTimeTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(locale: :en)
    @creative = Collavre::Creative.create!(user: @user, description: "Timing")
    @task = Collavre::Task.create!(name: "Timed task", agent: @user, status: "done")
    @comment = @creative.comments.create!(user: @user, task: @task, content: "Reply")
    started_at = 100.seconds.ago
    @task.task_actions.create!(action_type: "start", status: "done", created_at: started_at)
    @task.task_actions.create!(action_type: "completion", status: "done", created_at: started_at + 83)
    sign_in_as(@user, password: "password")
  end

  { en: "1m 23s", ko: "1분 23초" }.each do |locale, duration|
    test "shows #{locale} duration next to the timestamp before expanding logs" do
      @user.update!(locale: locale)
      get creative_comments_path(@creative)

      assert_response :success
      assert_select "#comment_#{@comment.id} time + .comment-execution-time", text: "(#{duration})" do |elements|
        assert_equal I18n.t("collavre.comments.activity_logs.duration", locale: locale, duration: duration), elements.first["aria-label"]
        assert_equal I18n.t("collavre.comments.activity_logs.duration_hint", locale: locale), elements.first["title"]
      end
      assert_select "#comment_#{@comment.id} time[datetime][title]", count: 1
    end
  end

  test "shows active and unavailable task states inline" do
    @task.update!(status: "running")
    get creative_comments_path(@creative)
    assert_response :success
    assert_select ".comment-execution-time", text: "(In progress)"

    @task.update!(status: "done")
    @task.task_actions.where(action_type: "completion").delete_all
    get creative_comments_path(@creative)
    assert_response :success
    assert_select ".comment-execution-time", text: "(Unavailable)"
  end

  test "does not add parentheses to comments without a task" do
    @comment.update!(task: nil)
    get creative_comments_path(@creative)

    assert_response :success
    assert_select "#comment_#{@comment.id} time[datetime]", count: 1
    assert_select ".comment-execution-time", count: 0
  end

  test "broadcast renderer can render the inline duration" do
    html = ApplicationController.render(partial: "collavre/comments/comment", locals: { comment: @comment })
    fragment = Nokogiri::HTML.fragment(html)

    assert_equal "(1m 23s)", fragment.at_css("time + .comment-execution-time").text
  end
end
