# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # A Review request is not "another comment in the burst": it is an action
    # bound to one specific quoted comment. ResponseFinalizer and Matcher both
    # derive that behaviour from the surviving anchor alone, so any step that
    # moves the anchor off a review comment — coalescing it away, or refreshing
    # it forward — silently downgrades an in-place revision to a normal reply.
    class ReviewActionBoundaryTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Review boundary", creative: @creative, user: @user)
      end

      def comment(body, user: @user, quoting: nil)
        Comment.create!(
          creative: @creative, user: user, topic: @topic, content: body,
          quoted_comment: quoting, skip_dispatch: true
        )
      end

      # The Review button quotes an agent's own comment; review_type stays nil.
      def review_request(body = "make it shorter")
        comment(body, quoting: comment("agent draft", user: @agent))
      end

      def waiter_for(trigger, status: "queued")
        Task.create!(
          name: "Response to comment_created", status: status,
          trigger_event_name: "comment_created", agent: @agent,
          topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => @topic.id },
            "comment" => {
              "id" => trigger.id, "content" => trigger.content, "user_id" => trigger.user_id
            },
            "chat" => { "content" => trigger.content }
          }
        )
      end

      def merged_ids(task)
        Array(task.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY])
      end

      test "an ordinary comment does not absorb a queued review request" do
        review_task = waiter_for(review_request)
        ordinary_task = waiter_for(comment("unrelated question"))

        absorbed = TaskCoalescer.coalesce!(ordinary_task)

        assert_empty absorbed, "the review request must keep its own turn"
        assert_equal "queued", review_task.reload.status
        assert_empty merged_ids(ordinary_task)
      end

      test "a review request absorbs no ordinary siblings" do
        ordinary_task = waiter_for(comment("unrelated question"))
        review_task = waiter_for(review_request)

        absorbed = TaskCoalescer.coalesce!(review_task)

        assert_empty absorbed,
          "answering an unrelated comment must not be folded into the in-place revision"
        assert_equal "queued", ordinary_task.reload.status
        assert_empty merged_ids(review_task)
      end

      test "ordinary siblings still coalesce around a review request" do
        first = waiter_for(comment("burst 1"))
        waiter_for(review_request)
        newest = waiter_for(comment("burst 2"))

        absorbed = TaskCoalescer.coalesce!(newest)

        assert_equal [ first.id ], absorbed
        assert_equal "cancelled", first.reload.status
      end

      test "promotion does not move an ordinary waiter onto a review request" do
        ordinary = comment("summarise the thread")
        task = waiter_for(ordinary)
        review_request

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        payload = task.reload.trigger_event_payload
        assert_equal ordinary.id, payload.dig("comment", "id"),
          "re-anchoring an ordinary turn onto a review makes it overwrite the quoted comment"
        assert_empty merged_ids(task)
        refute_equal "cancelled", task.status,
          "excluding reviews as destinations must not strand a waiter with a live anchor"
      end

      test "an ordinary waiter still refreshes forward onto a newer ordinary comment" do
        task = waiter_for(comment("stale trigger"))
        review_request
        newest = comment("the message actually worth answering")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal newest.id, task.reload.trigger_event_payload.dig("comment", "id"),
          "the exclusion must skip reviews, not freeze the refresh"
      end

      test "promotion keeps a review request pointed at the comment it reviews" do
        review = review_request
        task = waiter_for(review)
        comment("a later, unrelated message")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal review.id, task.reload.trigger_event_payload.dig("comment", "id"),
          "refreshing the anchor forward turns the review into a plain reply"
        assert_empty merged_ids(task)
      end
    end
  end
end
