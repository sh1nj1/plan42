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

    # A topic gets exactly one deduplicated waiting notice
    # (AgentOrchestrator.with_deduped_topic_notice), so that one comment is the
    # only wait/stop signal every queued waiter in the topic has. Cancelling just
    # the newest — which was right when each deferral posted its own notice —
    # now leaves the other waiters running with nothing on screen representing
    # them and no way to stop them.
    test "deleting the shared waiting notice cancels every waiter it represents" do
      other_agent = Collavre::User.create!(
        name: "Second AI Agent",
        email: "ai-agent-test-2@example.com",
        password: "password123",
        llm_vendor: "google",
        llm_model: "gemini-3-flash-preview"
      )

      older_task = Task.create!(
        name: "Older queued work",
        status: "queued",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 990 } }
      )

      # A different agent's waiter: coalescing folds same-agent siblings only, so
      # this one is deliberately left queued and the shared notice speaks for it.
      newer_task = Task.create!(
        name: "Newer queued work",
        status: "queued",
        agent: other_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 991 } }
      )

      # Which kind of notice this is used to be inferred from whether a sibling
      # notice survived; it is recorded on the row now, so a hand-built fixture
      # has to say. The producers writing it is a separate question, and one this
      # fixture cannot answer — AiAgentJobTopicSlotTest drives the real doors.
      notice = @creative.comments.create!(
        content: "⏳ 대기중",
        topic_id: @topic.id,
        private: false,
        skip_default_user: true,
        topic_concurrency_defer: true,
        waiting_notice_scope: Comment::WAITING_NOTICE_TOPIC
      )

      notice.destroy!

      assert_equal "cancelled", newer_task.reload.status
      assert_equal "cancelled", older_task.reload.status,
                   "the one notice a topic is allowed stands for every queued waiter in it"
    end

    # Control: "every waiter" is every *waiter*. A task that already holds the
    # topic slot is not waiting on anything, and the notice's stop button targets
    # it separately (topic_blocking_task) — deleting the notice must not cancel
    # the work that is actually running.
    test "deleting the shared waiting notice leaves the slot holder alone" do
      blocker = Task.create!(
        name: "Running blocker",
        status: "running",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 992 } }
      )

      claimed = Task.create!(
        name: "Claimed, not started",
        status: "pending",
        agent: @ai_agent,
        creative_id: @creative.id,
        topic_id: @topic.id,
        trigger_event_name: "comment.created",
        trigger_event_payload: { "comment" => { "id" => 993 } }
      )

      notice = @creative.comments.create!(
        content: "⏳ 대기중",
        topic_id: @topic.id,
        private: false,
        skip_default_user: true,
        topic_concurrency_defer: true
      )

      notice.destroy!

      assert_equal "running", blocker.reload.status
      assert_equal "pending", claimed.reload.status
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
