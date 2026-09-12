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
        assert_equal "note", elements.first["role"]
        assert_equal I18n.t("collavre.comments.activity_logs.duration", locale: locale, duration: duration), elements.first["aria-label"]
        assert_equal I18n.t("collavre.comments.activity_logs.inline_duration_hint", locale: locale), elements.first["title"]
      end
      assert_select "#comment_#{@comment.id} time[datetime][title]", count: 1
    end
  end

  test "hides inline timing for active unsuccessful and historical tasks" do
    %w[running pending queued delegated pending_approval failed cancelled escalated].each do |status|
      @task.update!(status: status)
      get creative_comments_path(@creative)
      assert_response :success
      assert_select ".comment-execution-time", count: 0
    end

    @task.update!(status: "done")
    @task.task_actions.where(action_type: "completion").delete_all
    get creative_comments_path(@creative)
    assert_response :success
    assert_select ".comment-execution-time", count: 0
  end

  test "loads timing events once per page including pagination and topic filtering" do
    topic = @creative.topics.create!(name: "Timed replies", user: @user)
    @comment.update!(topic: topic)
    7.times do
      task = Collavre::Task.create!(name: "Timed task", agent: @user, status: "done")
      @creative.comments.create!(user: @user, topic: topic, task: task, content: "Another reply")
      task.task_actions.create!(action_type: "start", status: "done", created_at: 30.seconds.ago)
      task.task_actions.create!(action_type: "completion", status: "done", created_at: 10.seconds.ago)
    end

    [ {}, { topic_id: topic.id }, { after_id: @comment.id },
      { before_id: @creative.comments.maximum(:id) + 1 } ].each do |parameters|
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        queries << payload[:sql] if payload[:sql].match?(/SELECT.*FROM "task_actions"/)
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get creative_comments_path(@creative), params: parameters
      end

      assert_response :success
      assert_select ".comment-execution-time", count: parameters[:after_id] ? 7 : 8
      assert_equal 1, queries.size, queries.join("\n")
    end
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
