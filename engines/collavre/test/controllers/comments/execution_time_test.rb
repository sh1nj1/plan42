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

  %i[en ko].each do |locale|
    test "preserves #{locale} comment timestamp without execution time" do
      @user.update!(locale: locale)
      get creative_comments_path(@creative)

      assert_response :success
      assert_select "#comment_#{@comment.id} time[datetime][title]", count: 1
      assert_select ".comment-execution-time, .activity-execution-time", count: 0
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

  test "does not load timing events on comment pages including pagination and topic filtering" do
    topic = @creative.topics.create!(name: "Timed replies", user: @user)
    @comment.update!(topic: topic)
    7.times do
      task = Collavre::Task.create!(name: "Timed task", agent: @user, status: "done")
      @creative.comments.create!(user: @user, topic: topic, task: task, content: "Another reply")
      task.task_actions.create!(action_type: "start", status: "done", created_at: 30.seconds.ago)
      task.task_actions.create!(action_type: "completion", status: "done", created_at: 10.seconds.ago)
    end

    [ {}, { topic_id: topic.id }, { after_id: @comment.id },
      { before_id: @creative.comments.maximum(:id) + 1 }, { around_comment_id: @comment.id } ].each do |parameters|
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) do
        queries << payload[:sql] if payload[:sql].match?(/SELECT.*FROM "task_actions"/)
      end
      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
        get creative_comments_path(@creative), params: parameters
      end

      assert_response :success
      assert_select "time[datetime]", count: parameters[:after_id] ? 7 : 8
      assert_select ".comment-execution-time, .activity-execution-time", count: 0
      assert_equal 0, queries.size, queries.join("\n")
    end
  end

  test "does not add parentheses to comments without a task" do
    @comment.update!(task: nil)
    get creative_comments_path(@creative)

    assert_response :success
    assert_select "#comment_#{@comment.id} time[datetime]", count: 1
    assert_select ".comment-execution-time", count: 0
  end

  test "broadcast renderer preserves timestamp without timing" do
    html = ApplicationController.render(partial: "collavre/comments/comment", locals: { comment: @comment })
    fragment = Nokogiri::HTML.fragment(html)

    assert fragment.at_css("time[datetime][title]")
    assert_nil fragment.at_css(".comment-execution-time, .activity-execution-time")
  end
end
