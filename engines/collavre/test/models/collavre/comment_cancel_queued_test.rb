# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentCancelQueuedTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @topic = @creative.topics.create!(name: "Test Topic", user: @user)
      @ai_agent = Collavre::User.create!(
        name: "AI Agent",
        email: "ai-agent-test@example.com",
        password: "password123",
        llm_vendor: "google",
        llm_model: "gemini-2.5-flash"
      )
    end

    test "deleting waiting notice cancels queued tasks for same creative/topic" do
      task = Task.create!(
        name: "Queued work",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 999 } }
      )

      notice = @creative.comments.create!(
        content: "⏳ 대기중 (이 토픽에서 다른 작업이 실행 중)",
        topic_id: @topic.id,
        private: false,
        skip_default_user: true
      )

      assert_equal "queued", task.reload.status

      notice.destroy!

      assert_equal "cancelled", task.reload.status
    end

    test "deleting waiting notice does not cancel tasks in other topics" do
      other_topic = @creative.topics.create!(name: "Other Topic", user: @user)

      task = Task.create!(
        name: "Other topic task",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: other_topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 888 } }
      )

      notice = @creative.comments.create!(
        content: "⏳ 대기중",
        topic_id: @topic.id,
        private: false,
        skip_default_user: true
      )

      notice.destroy!

      assert_equal "queued", task.reload.status
    end

    test "deleting normal comment does not cancel queued tasks" do
      task = Task.create!(
        name: "Queued work",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 777 } }
      )

      normal_comment = @creative.comments.create!(
        content: "Just a regular comment",
        topic_id: @topic.id,
        user: @user
      )

      normal_comment.destroy!

      assert_equal "queued", task.reload.status
    end

    test "deleting trigger comment cancels its associated task" do
      comment = @creative.comments.create!(
        content: "Do something",
        topic_id: @topic.id,
        user: @user
      )

      task = Task.create!(
        name: "Triggered work",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => comment.id } }
      )

      comment.destroy!

      assert_equal "cancelled", task.reload.status
    end
  end
end
