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
        llm_model: "gemini-3-flash-preview"
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
        skip_default_user: true,
        topic_concurrency_defer: true
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
        skip_default_user: true,
        topic_concurrency_defer: true
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

    test "deleting waiting notice cancels only the latest queued task" do
      older_task = Task.create!(
        name: "Older queued work",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 990 } }
      )

      newer_task = Task.create!(
        name: "Newer queued work",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 991 } }
      )

      notice = @creative.comments.create!(
        content: "⏳ 대기중",
        topic_id: @topic.id,
        private: false,
        skip_default_user: true,
        topic_concurrency_defer: true
      )

      notice.destroy!

      assert_equal "queued", older_task.reload.status
      assert_equal "cancelled", newer_task.reload.status
    end

    test "deleting a non-concurrency :delayed notice does not cancel an unrelated queued waiter" do
      # A genuine topic-concurrency waiter from a separate :deferred dispatch.
      waiter = Task.create!(
        name: "Concurrency waiter",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 555 } }
      )

      # A :delayed (busy / rate_limited) notice shares the "⏳" prefix but queues
      # no waiter of its own (topic_concurrency_defer: false). Deleting it must
      # not abandon the unrelated concurrency waiter above.
      delayed_notice = @creative.comments.create!(
        content: "⏳ 대기중 (잠시 후 재시도)",
        topic_id: @topic.id,
        private: false,
        skip_default_user: true,
        topic_concurrency_defer: false
      )

      delayed_notice.destroy!

      assert_equal "queued", waiter.reload.status
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
