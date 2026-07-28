# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # What a running turn actually handed the agent, recorded rather than
    # inferred from the agent's status.
    #
    # "The agent is busy" is not the same question as "the agent has already
    # read that comment", and the two answers diverge by agent kind: a
    # non-session turn re-reads the topic at execution time and swallows
    # whatever landed in the meantime, while a session-backed turn is sent only
    # its :trigger and swallows nothing.
    class DeliveryRecordTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Delivery topic", creative: @creative, user: @user)
      end

      def comment(body)
        Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: body, skip_dispatch: true
        )
      end

      def context_for(anchor)
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => @user.id, "name" => @user.name },
          "comment" => { "id" => anchor.id, "content" => anchor.content, "user_id" => @user.id },
          "chat" => { "content" => anchor.content }
        }
      end

      def task_for(anchor, status: "running", agent: @agent, event: "comment_created",
                   topic_id: @topic.id, creative_id: @creative.id)
        payload = context_for(anchor)
        payload["topic"] = { "id" => topic_id }
        payload["creative"] = { "id" => creative_id }
        Task.create!(
          name: "Turn", status: status, trigger_event_name: event, agent: agent,
          topic_id: topic_id, creative_id: creative_id, trigger_event_payload: payload
        )
      end

      def session_agent
        @session_agent ||= Collavre::User.create!(
          name: "delivery-session-agent",
          email: "delivery-session-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "google", llm_model: "gemini-1.5-flash",
          system_prompt: "You are a session agent.",
          agent_conf: "session:\n  enabled: true\n"
        )
      end

      # Built through MessageBuilder and SessionContextResolver rather than by
      # hand: the record has to describe the payload the adapter is handed, and
      # a fixture assembled here could assert a shape neither one produces.
      def resolved_for(task, agent)
        context = task.trigger_event_payload
        data = AiAgent::MessageBuilder.new(
          agent: agent, context: context,
          original_comment: Comment.find_by(id: context.dig("comment", "id"))
        ).build
        AiAgent::SessionContextResolver.new(
          agent: agent, messages_data: data, system_prompt: "prompt"
        ).resolve
      end

      def recorded(task)
        DeliveryRecord.ids_in(task.reload.trigger_event_payload)
      end

      test "a comment that landed after the turn was dispatched is recorded as delivered" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second, arrived while the turn was assembling")

        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_includes recorded(turn), late.id,
                        "chat history carried the late comment, so the turn delivered it"
      end

      # The whole point of asking the resolved payload rather than the agent's
      # status. A session-backed agent is sent only its :trigger, so a comment
      # that merely coexisted with the turn was never handed over — recording it
      # would licence dropping a message nobody ever read.
      test "a session-backed turn records nothing it was never sent" do
        anchor = comment("first")
        turn = task_for(anchor, agent: session_agent)
        late = comment("second, arrived while the turn was assembling")

        DeliveryRecord.record!(turn, resolved_for(turn, session_agent))

        assert_empty recorded(turn),
                     "incremental_payload drops chat history, so nothing was delivered"
        assert_not_includes recorded(turn), late.id
      end

      # Negative control for the id restriction. The backlog of a topic is
      # ordinary context, not something this turn swallowed, and counting it
      # would silence waiters parked long before this turn existed.
      test "history older than the anchor is not recorded" do
        old = comment("last week's message")
        anchor = comment("the trigger")
        turn = task_for(anchor)

        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_not_includes recorded(turn), old.id,
                            "the backlog is context, not a comment this turn absorbed"
      end

      test "nothing is recorded before the payload resolves" do
        anchor = comment("first")
        turn = task_for(anchor)
        comment("second")

        assert_empty recorded(turn),
                     "a turn that has not assembled yet must not silence anything"
      end

      # A resumed turn (pending_approval, or a retry) assembles a second time.
      # Whatever it delivered on the first pass it still delivered.
      test "a second pass accumulates rather than replaces the record" do
        anchor = comment("first")
        turn = task_for(anchor)
        first_late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        moved = TaskCoalescer.reanchor_payload(turn.reload.trigger_event_payload, first_late)
        turn.update!(trigger_event_payload: moved)
        second_late = comment("third")
        DeliveryRecord.record!(turn.reload, resolved_for(turn, @agent))

        assert_includes recorded(turn), first_late.id,
                        "a re-anchor must not erase what the first pass delivered"
        assert_includes recorded(turn), second_late.id
      end

      test "a running turn's record covers a later dispatch of the same comment" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_equal turn.id,
                     DeliveryRecord.covering_task(@agent, late.id, context_for(late), "comment_created")&.id
      end

      test "an un-started turn covers nothing" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))
        turn.update!(status: "queued")

        assert_nil DeliveryRecord.covering_task(@agent, late.id, context_for(late), "comment_created"),
                   "a queued row has delivered nothing, whatever its payload says"
      end

      # A turn that has finished is no longer answering, so a dispatch arriving
      # afterwards gets its own turn rather than being silently discarded. The
      # promotion door still reads the same record for waiters already parked —
      # that side may cancel, because a parked waiter has an alternative.
      test "a finished turn does not drop a fresh dispatch" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))
        turn.update!(status: "done")

        assert_nil DeliveryRecord.covering_task(@agent, late.id, context_for(late), "comment_created")
      end

      test "delivery is per agent" do
        other = Collavre::User.create!(
          name: "delivery-other-agent",
          email: "delivery-other-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai", llm_model: "gpt-4", system_prompt: "You are another agent."
        )
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_nil DeliveryRecord.covering_task(other, late.id, context_for(late), "comment_created"),
                   "one agent's reading is not another agent's"
      end

      test "delivery is per trigger event" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_nil DeliveryRecord.covering_task(@agent, late.id, context_for(late), "comment_updated"),
                   "a different event over the same comment is a different question"
      end

      test "delivery is per topic" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        other_topic = Topic.create!(name: "Elsewhere", creative: @creative, user: @user)
        elsewhere = context_for(late).merge("topic" => { "id" => other_topic.id })

        assert_nil DeliveryRecord.covering_task(@agent, late.id, elsewhere, "comment_created")
      end

      # A review request is bound to the comment it quotes and can only run as
      # its own turn (ReviewHandler reads the anchor, not the history window).
      # Having been read as context is not having been answered.
      test "a review request is never covered" do
        anchor = comment("first")
        turn = task_for(anchor)
        target = Comment.create!(
          creative: @creative, user: @agent, topic: @topic,
          content: "the agent's answer", skip_dispatch: true
        )
        review = Comment.create!(
          creative: @creative, user: @user, topic: @topic, content: "tighten this up",
          quoted_comment: target, skip_dispatch: true
        )
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_nil DeliveryRecord.covering_task(@agent, review.id, context_for(review), "comment_created"),
                   "a review has to keep its own turn"
      end

      test "the policy switch turns the drop off without disturbing the record" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: "Creative", scope_id: @creative.id,
          config: { "drop_delivered_dispatches" => false }
        )

        assert_includes recorded(turn), late.id,
                        "the record is evidence, and stays true whatever the switch says"
        assert_nil DeliveryRecord.covering_task(@agent, late.id, context_for(late), "comment_created")
      end
    end
  end
end
