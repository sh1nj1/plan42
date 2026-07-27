# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # Coalescing folds the *tasks* that exist when a burst is claimed, but the
    # promotion door's refresh moves the anchor onto the newest comment in the
    # topic — which need not be one of them. A comment is visible the instant its
    # transaction commits, while the queued Task representing it only appears
    # once its AiAgentJob runs. A turn refreshed inside that gap answers a
    # comment whose own waiter is still on its way, and that waiter is promoted
    # later and answers it a second time.
    #
    # The invariant here is delivery-side: a comment already handed to an agent
    # by a turn that was not created to answer it is not handed over again.
    # Asking at promotion rather than at dispatch is what keeps it loss-free — by
    # then the covering turn's status says whether it delivered anything at all.
    class DeliveredCommentDedupTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Dedup topic", creative: @creative, user: @user)
      end

      def comment(body)
        Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: body, skip_dispatch: true
        )
      end

      def payload_for(anchor, merged: [])
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => @user.id, "name" => @user.name },
          "comment" => { "id" => anchor.id, "content" => anchor.content, "user_id" => @user.id },
          "chat" => { "content" => anchor.content },
          TaskCoalescer::PAYLOAD_KEY => merged.map(&:id)
        }
      end

      def task_for(status, anchor, agent: @agent, merged: [])
        Task.create!(
          name: "Task #{status}", status: status, trigger_event_name: "comment_created",
          agent: agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: payload_for(anchor, merged: merged)
        )
      end

      # A turn parked for `anchor` before `acquired` existed, then re-anchored
      # onto it by the refresh — the shape the promotion door produces, and the
      # only shape where a second task for the same comment can still be queued.
      def turn_that_acquired(status, anchor, acquired, agent: @agent)
        turn = task_for(status, anchor, agent: agent)
        turn.update_columns(created_at: 2.minutes.ago)
        turn.update!(trigger_event_payload: payload_for(acquired, merged: [ anchor ]))
        turn
      end

      def merged_ids(task)
        Array(task.reload.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY])
      end

      # The reported path, through the door the absorbed_only narrowing leaves
      # open by design.
      test "a waiter is cancelled rather than re-answering a comment a finished turn acquired" do
        b = comment("do X")
        c = comment("actually do Y")
        turn_that_acquired("done", b, c)
        late = task_for("queued", c)

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "cancelled", late.reload.status,
                     "a waiter whose whole burst was already delivered must not answer it again"
      end

      # The same question one level down: MessageBuilder renders merged blocks
      # into the trigger exactly like the anchor, so the comment the refresh
      # displaces can itself be one an earlier turn already answered.
      test "comments a finished turn acquired are dropped from the merged list" do
        b = comment("do X")
        c = comment("actually do Y")
        turn_that_acquired("done", b, c)
        late = task_for("queued", c)
        d = comment("and also Z")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal d.id, late.reload.trigger_event_payload.dig("comment", "id"),
                     "the waiter should move onto the one comment nobody has answered"
        assert_not_includes merged_ids(late), c.id,
                            "an already delivered comment must not be re-sent as a merged block"
      end

      # Control for the discriminator itself, and the reason it is not simply
      # "any delivered task": the overwhelmingly common history is one comment
      # answered by its own turn. That must silence nothing, or every waiter
      # behind an answered comment would be cancelled.
      test "a comment delivered by its own turn does not cancel a waiter anchored on it" do
        c = comment("do X")
        # Created after the comment, so the comment is this turn's own trigger.
        task_for("done", c)
        late = task_for("queued", c)

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_not_equal "cancelled", late.reload.status,
                         "a comment answered by the turn created for it is not an acquired delivery"
        assert_equal c.id, late.reload.trigger_event_payload.dig("comment", "id")
      end

      # Control against trading a duplicate answer for a lost one: a turn that
      # died without delivering leaves its comments answerable. `cancelled` is
      # reachable — refresh_deferred_context! and revalidate_assignment! both
      # cancel a claimed waiter outright.
      test "a comment stays answerable when the turn that acquired it died undelivered" do
        b = comment("do X")
        c = comment("actually do Y")
        turn_that_acquired("cancelled", b, c)
        late = task_for("queued", c)

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_not_equal "cancelled", late.reload.status,
                         "a turn that died undelivered must not silence the comment it held"
        assert_equal c.id, late.reload.trigger_event_payload.dig("comment", "id")
      end

      # Control against freezing the refresh: an unanswered newer comment is
      # still what a promoted waiter moves onto. That is what the refresh is for.
      test "a waiter still moves onto a newer comment nobody has delivered" do
        b = comment("do X")
        waiter = task_for("queued", b)
        c = comment("actually do Y")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal c.id, waiter.reload.trigger_event_payload.dig("comment", "id"),
                     "the refresh must still carry a waiter forward onto unanswered comments"
        assert_includes merged_ids(waiter), b.id,
                        "and the anchor it left behind is still delivered as a merged block"
      end

      # Delivery is per agent. Without this the dedup would let one agent's
      # answer silence another agent's trigger.
      test "another agent's delivered turn does not silence this agent's waiter" do
        other = Collavre::User.create!(
          name: "dedup-other-agent",
          email: "dedup-other-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai", llm_model: "gpt-4", system_prompt: "You are another agent."
        )
        b = comment("do X")
        c = comment("actually do Y")
        turn_that_acquired("done", b, c, agent: other)
        late = task_for("queued", c)

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_not_equal "cancelled", late.reload.status,
                         "delivery is per agent: another agent's turn is not this agent's answer"
      end
    end
  end
end
