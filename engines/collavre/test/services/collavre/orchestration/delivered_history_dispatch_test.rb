# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # Event A and event B arrive as a burst; the agent starts a turn for A. A
    # non-session turn reads the topic when it assembles its payload, so B is
    # already inside it — the agent has read B. B's own dispatch should be
    # dropped rather than parked behind the turn, and a waiter that was parked
    # before the turn assembled should be cancelled at promotion.
    #
    # The boundary is the resolved payload, not the agent's status: a
    # session-backed turn is sent only its :trigger and swallows nothing, so
    # nothing is dropped for one.
    class DeliveredHistoryDispatchTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @agent.update!(searchable: true, routing_expression: "true")

        share = CreativeShare.find_or_create_by!(creative: @creative, user: @agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: @agent.id, permission: :feedback
        )

        @topic = Topic.create!(name: "Burst topic", creative: @creative, user: @user)
        ResourceTracker.for(@agent).reset!
      end

      teardown do
        ResourceTracker.for(@agent).reset!
      end

      def session_agent
        @session_agent ||= begin
          agent = Collavre::User.create!(
            name: "dispatch-session-agent",
            email: "dispatch-session-#{SecureRandom.hex(4)}@agent.test",
            password: "password123",
            llm_vendor: "google", llm_model: "gemini-1.5-flash",
            system_prompt: "You are a session agent.", searchable: true,
            routing_expression: "true", agent_conf: "session:\n  enabled: true\n"
          )
          share = CreativeShare.find_or_create_by!(creative: @creative, user: agent)
          share.update!(permission: "feedback")
          CreativeSharesCache.find_or_create_by!(
            creative_id: @creative.id, user_id: agent.id, permission: :feedback
          )
          agent
        end
      end

      def comment(body, user: @user)
        Comment.create!(
          creative: @creative, user: user, topic: @topic, content: body, skip_dispatch: true
        )
      end

      def context_for(target)
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id },
          "sender" => { "id" => @user.id, "name" => @user.name },
          "chat" => { "content" => target.content },
          "comment" => { "id" => target.id, "content" => target.content, "user_id" => @user.id }
        }
      end

      # The running turn, with its record written the way AiAgentService writes
      # it: off the payload MessageBuilder and SessionContextResolver actually
      # produce, so the fixture cannot assert a delivery the real path would not
      # have made.
      def running_turn(anchor, agent: @agent)
        turn = Task.create!(
          name: "Turn", status: "running", trigger_event_name: "comment_created",
          agent: agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(anchor)
        )
        data = AiAgent::MessageBuilder.new(
          agent: agent, context: turn.trigger_event_payload, original_comment: anchor
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(turn, resolved)
        turn.reload
      end

      def dispatch(target, agent: @agent)
        AgentOrchestrator.dispatch("comment_created", context_for(target))
      end

      def tasks_for(agent)
        Task.where(agent: agent, topic_id: @topic.id).where.not(status: "running")
      end

      def waiting_notices
        @creative.comments.where(topic_id: @topic.id, topic_concurrency_defer: true)
                 .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
      end

      test "a comment the running turn already read produces no task and no waiting notice" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        assert_includes DeliveryRecord.ids_in(turn.trigger_event_payload), late.id,
                        "premise: the running turn's history carried the late comment"

        dispatch(late)

        assert_empty tasks_for(@agent),
                     "the agent has already read that comment; queueing it answers nothing new"
        assert_empty waiting_notices,
                     "and there is nobody to wait for, so no ⏳ notice either"
      end

      # Control against the drop swallowing ordinary bursts: without a record,
      # nothing has been delivered and the waiter must still be parked.
      test "a comment no turn has read is still queued" do
        anchor = comment("@#{@agent.name}: first")
        Task.create!(
          name: "Holder", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(anchor)
        )
        late = comment("@#{@agent.name}: second")

        dispatch(late)

        assert_equal 1, tasks_for(@agent).where(status: "queued").count,
                     "a turn that has not assembled yet has delivered nothing"
        assert_equal 1, waiting_notices.count
      end

      # The reason the predicate is the resolved payload rather than "the agent
      # is busy". A session-backed turn is sent only its :trigger, so dropping
      # here would lose the message outright.
      test "a session-backed turn never drops the comments beside it" do
        anchor = comment("@#{session_agent.name}: first")
        late = comment("@#{session_agent.name}: second")
        turn = running_turn(anchor, agent: session_agent)
        assert_empty DeliveryRecord.ids_in(turn.trigger_event_payload),
                     "premise: incremental_payload carries no chat history"

        dispatch(late, agent: session_agent)

        assert_equal 1, tasks_for(session_agent).where(status: "queued").count,
                     "a session agent's burst is coalesced, never discarded"
      end

      test "the policy switch keeps the dispatch queued" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: "Creative", scope_id: @creative.id,
          config: { "drop_delivered_dispatches" => false }
        )
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        running_turn(anchor)

        dispatch(late)

        assert_equal 1, tasks_for(@agent).where(status: "queued").count
      end

      # A review is bound to the comment it quotes and can only run as its own
      # turn. Having been swept into a history window is not having been
      # answered.
      test "a review request is queued even when the running turn read it" do
        anchor = comment("@#{@agent.name}: first")
        target = comment("the agent's earlier answer", user: @agent)
        review = Comment.create!(
          creative: @creative, user: @user, topic: @topic,
          content: "@#{@agent.name}: tighten this up", quoted_comment: target, skip_dispatch: true
        )
        turn = running_turn(anchor)
        assert_includes DeliveryRecord.ids_in(turn.trigger_event_payload), review.id,
                        "premise: the review did land in the running turn's history"

        dispatch(review)

        assert_equal 1, tasks_for(@agent).where(status: "queued").count,
                     "a review keeps its own turn"
      end

      # Two doors lead into the queue. An :immediate decision creates no Task at
      # the orchestrator at all — the row is created inside AiAgentJob — so a
      # dispatch can be enqueued before the covering turn assembles and become
      # droppable only by the time the job runs.
      test "the job door drops a dispatch the covering turn read while it waited" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        context = context_for(late)
        running_turn(anchor)

        AiAgentJob.new.perform(@agent.id, "comment_created", context)

        assert_empty tasks_for(@agent),
                     "the late-admission door has to ask the same question the enqueue door did"
        assert_empty Task.where(agent: @agent, topic_id: @topic.id, status: "running")
                         .where.not(trigger_event_payload: nil)
                         .select { |t| t.trigger_event_payload.dig("comment", "id") == late.id },
                     "and must not admit it as a second concurrent turn either"
      end

      # The window the dispatch doors cannot close: the waiter was parked before
      # the covering turn assembled, so nothing was recorded to drop it against.
      # Promotion is where it is finally discoverable.
      test "a waiter parked before the turn assembled is cancelled at promotion" do
        anchor = comment("@#{@agent.name}: first")
        holder = Task.create!(
          name: "Holder", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(anchor)
        )
        late = comment("@#{@agent.name}: second")
        dispatch(late)
        waiter = tasks_for(@agent).where(status: "queued").sole
        assert_equal late.id, waiter.trigger_event_payload.dig("comment", "id")

        data = AiAgent::MessageBuilder.new(
          agent: @agent, context: holder.trigger_event_payload, original_comment: anchor
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: @agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(holder, resolved)
        holder.update!(status: "done")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "cancelled", waiter.reload.status,
                     "the covering turn read that comment; the waiter has nothing left to say"
        assert_empty waiting_notices,
                     "and the notice it was parked behind goes with it"
      end

      # Hold the topic slot so a restored dispatch parks as a waiter here
      # instead of being admitted and executed inline by the test adapter. What
      # is under test is that the dispatch exists again, not what it says.
      def slot_holder(anchor)
        Task.create!(
          name: "Holder", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(anchor)
        )
      end

      def restored_waiters
        tasks_for(@agent).where(status: "queued")
      end

      # The drop is only sound while the covering turn is still going to answer.
      # `failed` is kept out of DELIVERED_STATUSES precisely because a turn that
      # died may never have delivered anything — a *waiter* survives that,
      # because promotion re-reads the covering turn's status and refreshes it
      # normally. A dropped dispatch has no row left to refresh, so the drop has
      # to put back what it discarded.
      test "a dropped dispatch comes back when the covering turn fails" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        assert_empty tasks_for(@agent), "premise: the dispatch was dropped, leaving no row"

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "the comment the failed turn silenced has a turn of its own again"
      end

      # Cancellation is the other undelivered ending: the turn's own anchor was
      # deleted underneath it. The comments it swallowed were not deleted.
      test "a dropped dispatch comes back when the covering turn is cancelled" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        slot_holder(anchor)
        turn.update!(status: "cancelled")

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") }
      end

      # Control: the whole point of the drop. A turn that finished delivered
      # what it read, and putting the dispatch back would answer it twice.
      test "a completed turn restores nothing" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        slot_holder(anchor)
        turn.update!(status: "done")

        assert_empty restored_waiters,
                     "the agent read that comment and answered; there is nothing to restore"
      end

      # Control against restoring what was never dropped. A waiter parked before
      # the turn assembled still has its own row, and promotion — which reads the
      # failed turn's status — is what decides its fate. Restoring it as well
      # would put two turns on one comment.
      test "a comment that still has a task of its own is not restored" do
        anchor = comment("@#{@agent.name}: first")
        holder = slot_holder(anchor)
        late = comment("@#{@agent.name}: second")
        dispatch(late)
        waiter = restored_waiters.sole

        data = AiAgent::MessageBuilder.new(
          agent: @agent, context: holder.trigger_event_payload, original_comment: anchor
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: @agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(holder, resolved)
        holder.update!(status: "failed")

        assert_equal [ waiter.id ], restored_waiters.pluck(:id),
                     "the dispatch was parked, not discarded — it needs no restoring"
      end

      # The restore's subject is the dispatches this turn refused, and a comment
      # routed away from this agent never produced one. Chat history is the
      # whole topic — Matcher's exclusive routings do not filter it — so a
      # comment addressed to somebody else is read by every agent in the topic.
      # Treating "read it" as "dropped a dispatch for it" makes the failure of
      # an unrelated turn dispatch this agent onto a message that was never
      # meant for it, past Matcher entirely.
      test "a comment routed to somebody else is not restored to this agent" do
        anchor = comment("@#{@agent.name}: first")
        addressed_elsewhere = comment("@#{users(:two).name}: second, for you")
        turn = running_turn(anchor)
        assert_includes DeliveryRecord.ids_in(turn.trigger_event_payload), addressed_elsewhere.id,
                        "premise: the agent read it as history, as every agent in the topic does"

        dispatch(addressed_elsewhere)
        assert_empty tasks_for(@agent),
                     "premise: an exclusive mention routes past this agent, so no dispatch was refused"

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_empty restored_waiters,
                     "there was no dispatch to put back, and inventing one speaks out of turn"
      end

      # The other shape of the same inference. An :immediate decision enqueues
      # its job at AgentOrchestrator#enqueue_jobs and the Task row is only
      # created when that job runs, so between the two there is a live dispatch
      # with nothing in the table to show for it. "No row" cannot mean "was
      # dropped" while that window exists.
      test "a dispatch still sitting in the queue is not restored underneath itself" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")

        # The burst race the PR's own AiAgentJob guard describes: both comments
        # are judged :immediate because neither has a row yet, and the second
        # job is still queued when the first turn assembles and swallows it.
        previous_adapter = ActiveJob::Base.queue_adapter
        begin
          ActiveJob::Base.queue_adapter = :test
          dispatch(late)
          assert_empty tasks_for(@agent), "premise: the dispatch is enqueued with no Task row yet"
        ensure
          ActiveJob::Base.queue_adapter = previous_adapter
        end

        turn = running_turn(anchor)
        assert_includes DeliveryRecord.ids_in(turn.trigger_event_payload), late.id,
                        "premise: and the turn read it anyway"

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_empty restored_waiters,
                     "the dispatch is alive in the queue; a second one answers the comment twice"
      end

      # The only state in which a dropped comment also has a Task row of its
      # own: the row came from a *different* dispatch of the same comment, and
      # the one that was dropped is therefore the duplicate. Reproduced here so
      # the two controls below rest on a state that can actually arise.
      #
      # `duplicate_running_for_comment?` only looks for a *running* task, so a
      # queued waiter does not stop the second dispatch from reaching the drop
      # door — the guard the codebase already carries for redelivered events.
      def duplicate_dispatch_over_a_waiter
        anchor = comment("@#{@agent.name}: first")
        holder = slot_holder(anchor)
        late = comment("@#{@agent.name}: second")
        dispatch(late)
        waiter = restored_waiters.sole
        assert_equal late.id, waiter.trigger_event_payload.dig("comment", "id"),
                     "premise: the comment got a dispatch of its own, parked behind the slot"

        data = AiAgent::MessageBuilder.new(
          agent: @agent, context: holder.trigger_event_payload, original_comment: anchor
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: @agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(holder, resolved)

        dispatch(late)
        assert_includes DeliveryRecord.dropped_ids_in(holder.reload.trigger_event_payload), late.id,
                        "premise: the redelivered dispatch was the one dropped"
        assert_equal [ waiter.id ], restored_waiters.pluck(:id),
                     "premise: and it left no row of its own"

        [ holder, waiter, late, anchor ]
      end

      # Control: a terminal sibling is still coverage.
      #
      # The user pressed stop on the waiter — TasksController#cancel, one of the
      # four doors a waiter leaves the queue through. The covering turn then
      # fails, and its drop record still names that comment. Restoring it would
      # answer a comment whose turn the user cancelled, from a dispatch that was
      # only ever a duplicate of the cancelled one: `restore!` re-asks the
      # comment's eligibility but has no way to re-ask the user's decision.
      #
      # This is why claimed_comment_ids counts a task in any status. Narrowing
      # it to tasks "still capable of answering" reads a deliberate stop as an
      # absence of coverage.
      test "a comment whose own task the user stopped is not restored" do
        holder, waiter, _late, anchor = duplicate_dispatch_over_a_waiter
        waiter.update!(status: "cancelled")

        slot_holder(anchor)
        holder.update!(status: "failed")

        assert_empty restored_waiters,
                     "the comment had a turn and the user stopped it; a restore reverses that"
      end

      # Control: the same for a sibling that failed rather than was cancelled.
      #
      # Both turns have ended without delivering, which looks like the comment
      # is now unanswered — but its own dispatch did become a Task, and a failed
      # Task is the ordinary ending the product already shows and offers to
      # retry. The restore exists for the one ending that leaves nothing behind
      # at all: a dispatch discarded before it could become a row. Extending it
      # to comments whose turn failed makes it a general retry the rest of the
      # system does not have, and it fires on the duplicate rather than on the
      # turn that actually failed.
      test "a comment whose own task failed is not restored by the turn that read it" do
        holder, waiter, late, anchor = duplicate_dispatch_over_a_waiter
        waiter.update!(status: "failed")

        slot_holder(anchor)
        holder.update!(status: "failed")

        assert_empty restored_waiters,
                     "the comment had a turn of its own; its failure is that turn's, not a lost dispatch"
        assert_equal [ "failed", late.id ],
                     [ waiter.reload.status, waiter.trigger_event_payload.dig("comment", "id") ],
                     "and it is still visible as a failed task for that comment"
      end

      # A comment deleted while the turn ran has nothing to answer.
      test "a comment that no longer exists is not restored" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        late.destroy!

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_empty restored_waiters
      end

      # Nor has one the author took out of the turn while it ran. The restore
      # re-asks eligibility rather than trusting the record, which was written
      # when the comment was still eligible.
      test "a comment made private while the turn ran is not restored" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        late.update!(private: true)

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_empty restored_waiters
      end

      # The restored dispatch is the one that was discarded, not a descendant of
      # the turn that discarded it: it carries no delivery record, no merged list
      # and no acquired anchor. Without this a restored turn that fails again
      # would restore the same comments a second time.
      # A provider error is not a failed task. AiClient#chat catches
      # StandardError, streams "⚠️ AI Error" to the user and returns nil, and
      # AiAgentJob marks an ordinary task `done` on that — so the turn ends in
      # the one status DELIVERED_STATUSES counts as delivery, having handed the
      # provider nothing at all. The comments it discarded on the strength of
      # having read them were never read by anything.
      test "a dropped dispatch comes back when the covering turn's request never reached the provider" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        assert_empty tasks_for(@agent), "premise: the dispatch was dropped, leaving no row"

        slot_holder(anchor)
        DeliveryRecord.mark_handoff_failed!(turn)
        turn.reload.update!(status: "done")

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "nothing was handed over, so the comment it silenced has a turn of its own again"
      end

      # The other half of the same failure: while the turn is still `running`
      # after the error, it must stop covering anything further. Dropping
      # against it would record a drop the restore has already run past.
      test "a turn whose request never reached the provider stops covering later dispatches" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        assert_includes DeliveryRecord.ids_in(turn.trigger_event_payload), late.id,
                        "premise: the window did sweep it up"

        DeliveryRecord.mark_handoff_failed!(turn)
        dispatch(late)

        assert_equal 1, tasks_for(@agent).where(status: "queued").count,
                     "a turn that delivered nothing cannot be the reason a dispatch is discarded"
      end

      # And the promotion door, which reads the same record through
      # AgentOrchestrator.delivered_comment_ids and counts `done` as delivery.
      # The mirror of "a waiter parked before the turn assembled is cancelled at
      # promotion" above: that cancellation is right when the turn answered, and
      # is the waiter losing its only turn when the turn handed over nothing.
      test "a waiter is not cancelled at promotion by a turn that never handed anything over" do
        anchor = comment("@#{@agent.name}: first")
        holder = slot_holder(anchor)
        late = comment("@#{@agent.name}: second")
        dispatch(late)
        waiter = tasks_for(@agent).where(status: "queued").sole
        assert_equal late.id, waiter.trigger_event_payload.dig("comment", "id")

        data = AiAgent::MessageBuilder.new(
          agent: @agent, context: holder.trigger_event_payload, original_comment: anchor
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: @agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(holder, resolved)
        assert_includes DeliveryRecord.ids_in(holder.reload.trigger_event_payload), late.id,
                        "premise: the covering turn's window did carry the waiter's comment"

        DeliveryRecord.mark_handoff_failed!(holder)
        holder.reload.update!(status: "done")
        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_not_equal "cancelled", waiter.reload.status,
                         "nothing was handed over, so the waiter has not been answered"
        assert_equal late.id, waiter.trigger_event_payload.dig("comment", "id"),
                     "and it still answers the comment it was dispatched for"
      end

      # A dropped dispatch is handled, not unscheduled. AgentOrchestrator.dispatch
      # returns the agents that will answer — a :deferred decision returns its
      # agent although only a queued row exists — and a drop says this agent is
      # already answering that comment inside an in-flight turn. Returning
      # nothing instead makes DropTriggerJob#dispatch_trigger raise
      # DispatchFailedError and retry a trigger that was correctly covered.
      test "a dropped dispatch reports its agent rather than an empty result" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        running_turn(anchor)

        assert_equal [ @agent.id ], dispatch(late).map(&:id)
        assert_empty tasks_for(@agent), "premise: it really was dropped"
      end

      # Control: "handled" must not swallow the real empty result. A :rejected
      # decision — the agent is out of quota, or the loop breaker stopped it —
      # schedules nothing and answers nothing, and DropTriggerJob's retry is the
      # right response to that.
      test "a rejected decision still reports an empty result" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: "User", scope_id: @agent.id,
          config: { "daily_token_limit" => 1000 }
        )
        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("spent")
        tracker.release!("spent", tokens_used: 1500)

        late = comment("@#{@agent.name}: anybody there")

        assert_empty dispatch(late)
        assert_empty tasks_for(@agent), "premise: the decision really was :rejected"
      end

      test "the restored dispatch carries none of the dead turn's bookkeeping" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        slot_holder(anchor)
        turn.update!(status: "failed")

        payload = restored_waiters.sole.trigger_event_payload
        assert_empty DeliveryRecord.ids_in(payload)
        assert_empty DeliveryRecord.dropped_ids_in(payload)
        assert_empty Array(payload[TaskCoalescer::PAYLOAD_KEY])
        assert_nil payload[TaskCoalescer::ACQUIRED_ANCHOR_KEY]
        assert_equal late.content, payload.dig("chat", "content"),
                     "and it is anchored on the comment it was dispatched for"
      end

      # The enumerated strip above is only as good as its enumeration, and the
      # failed-handoff flag is the key it was missing. Stated as the rule the
      # comment on restored_context always claimed: a restored dispatch is the
      # one that was discarded, so it carries what a dispatch carries and
      # nothing the turn wrote onto itself afterwards.
      test "the restored dispatch carries no key the covering turn wrote onto itself" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        DeliveryRecord.mark_handoff_failed!(turn)

        added = turn.reload.trigger_event_payload.keys - context_for(anchor).keys
        assert_operator added.length, :>=, 3,
                        "premise: the turn did write bookkeeping onto its own payload"

        slot_holder(anchor)
        turn.reload.update!(status: "done")

        payload = restored_waiters.sole.trigger_event_payload
        assert_empty payload.keys - context_for(late).keys,
                     "a restored dispatch carries what a dispatch carries, and nothing else"
      end

      # The consequence, at the reader that makes it cost a duplicate reply.
      # covering_task refuses a turn whose handoff failed, so a restored turn
      # still carrying the dead turn's flag cannot cover anything it reads: the
      # next comment swept into its history dispatches beside it.
      test "a restored turn covers the comments it reads" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        DeliveryRecord.mark_handoff_failed!(turn)
        turn.reload.update!(status: "done")

        restored = restored_waiters.sole
        restored.update!(status: "running")
        third = comment("@#{@agent.name}: third")
        data = AiAgent::MessageBuilder.new(
          agent: @agent, context: restored.trigger_event_payload, original_comment: late
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: @agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(restored, resolved)
        assert_includes DeliveryRecord.ids_in(restored.reload.trigger_event_payload), third.id,
                        "premise: the restored turn's window did sweep the third comment up"

        dispatch(third)

        assert_empty tasks_for(@agent).where(status: "queued"),
                     "the restored turn has read it; a second turn beside it is the duplicate reply"
      end

      # Control: the flag is still the dead turn's own, so the fix cannot be
      # "stop recording it". Without it on the covering turn there is no restore
      # at all, and this is the row every reader of it is asking about.
      test "the turn that failed its handoff keeps the flag" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        DeliveryRecord.mark_handoff_failed!(turn)
        turn.reload.update!(status: "done")

        assert DeliveryRecord.handoff_failed?(turn.reload.trigger_event_payload),
               "the turn that handed nothing over is what the record is about"
      end

      # A dispatch the scheduler has refused is not a dispatch. The drop asks
      # "is this redundant?", which only makes sense about work that was going
      # to run: recording one against a :rejected decision manufactures a
      # restore obligation for a turn that was never scheduled, and restore!
      # enqueues AiAgentJob directly — past the quota check that refused it.
      def quota_exhausted!
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: "User", scope_id: @agent.id,
          config: { "daily_token_limit" => 1000 }
        )
        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("spent")
        tracker.release!("spent", tokens_used: 1500)
      end

      test "a dispatch the scheduler rejected is not recorded as a drop" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        assert_includes DeliveryRecord.ids_in(turn.trigger_event_payload), late.id,
                        "premise: the covering turn did read it, so the drop door is live"
        quota_exhausted!

        assert_empty dispatch(late),
                     "a rejected decision schedules nobody, drop door or not"
        assert_empty DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload),
                     "and refused work leaves nothing for the restore to owe"
      end

      test "a dispatch the scheduler rejected is not restored past the check that rejected it" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        quota_exhausted!
        dispatch(late)

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_empty restored_waiters,
                     "restoring it would run work the quota check refused"
      end

      # Control: the drop itself still happens for work that *was* going to be
      # scheduled — this is what holds the rejection guard to :rejected rather
      # than to "covered", which would turn the drop back into a plain skip.
      test "a dispatch the scheduler admitted is still dropped and recorded" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)

        assert_equal [ @agent.id ], dispatch(late).map(&:id)
        assert_includes DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload), late.id
      end

      # Re-anchoring moves the trigger onto a different comment, and everything
      # the payload derives from the anchor has to move with it. ContextBuilder
      # fills "chat"/"mentioned_user" with `||=` and does not run again on
      # either of these paths — AiAgentJob asks Matcher#assignment_permits?
      # against the raw payload — so a mention left behind reads as "no mention
      # at all", and an explicit mention is exactly what outranks a topic
      # assignment.
      test "re-anchoring rebuilds the mention from the comment it moves onto" do
        anchor = comment("first, to nobody")
        late = comment("@#{@agent.name}: second")
        payload = TaskCoalescer.reanchor_payload(context_for(anchor), late)

        assert_equal @agent.id, payload.dig("chat", "mentioned_user", "id")
      end

      # Control against carrying the old anchor's mention across: a rebuild
      # that finds nobody must leave the key absent, not stale. Matcher reads
      # its presence as the mention that outranks the assignment.
      test "re-anchoring onto a comment that mentions nobody leaves no mention behind" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("second, to nobody")
        payload = TaskCoalescer.reanchor_payload(
          SystemEvents::ContextBuilder.new(context_for(anchor)).build, late
        )

        assert_nil payload.dig("chat", "mentioned_user")
      end

      test "a restored dispatch that mentions this agent runs in a topic assigned to another" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        assert_includes DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload), late.id,
                        "premise: the dispatch was dropped, so only the restore can bring it back"

        @topic.update!(primary_agent_id: session_agent.id)
        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "an explicit mention outranks the assignment, as it did at dispatch"
      end

      # Control: the assignment check is still doing its job. Without a mention
      # of this agent there is nothing to outrank the reassignment, and the
      # restored dispatch must stay refused.
      test "a restored dispatch with no mention stays refused in a topic assigned to another" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("second, to nobody in particular")
        turn = running_turn(anchor)
        dispatch(late)

        @topic.update!(primary_agent_id: session_agent.id)
        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_empty restored_waiters,
                     "the topic belongs to another agent and nothing in the comment says otherwise"
      end
    end
  end
end
