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
          "comment" => { "id" => target.id, "content" => target.content, "user_id" => target.user_id }
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

      def topic_max!(value)
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "topic_max_concurrent_jobs" => value }
        )
      end

      def peer_agent(tag)
        agent = Collavre::User.create!(
          name: "burst-peer-#{tag}",
          email: "burst-peer-#{tag}-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai", llm_model: "gpt-4",
          system_prompt: "You are peer #{tag}.", searchable: true, routing_expression: "false"
        )
        share = CreativeShare.find_or_create_by!(creative: @creative, user: agent)
        share.update!(permission: "feedback")
        CreativeSharesCache.find_or_create_by!(
          creative_id: @creative.id, user_id: agent.id, permission: :feedback
        )
        agent
      end

      # Cancelling a waiter is the one removal this feature makes that writes
      # nothing down, so it is only sound against a turn whose delivery has
      # settled. DELIVERED_STATUSES counts `running`, and the refresh only
      # re-reads a status — what keeps that from deciding on an outcome nobody
      # knows yet is TopicSlot, not this file: an agent occupying a slot here
      # may not be promoted into a second turn. Pinned from this side too,
      # because relaxing that exclusion would cost a comment rather than a
      # duplicate turn, and silently.
      test "a waiter is not promoted while its own agent's covering turn is still in flight" do
        topic_max!(2)
        anchor = comment("@#{@agent.name}: first")
        holder = Task.create!(
          name: "Holder", status: "running", trigger_event_name: "comment_created",
          agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(anchor)
        )
        late = comment("@#{@agent.name}: second")
        dispatch(late)
        waiter = Task.where(agent: @agent, topic_id: @topic.id).where.not(id: holder.id).sole
        assert_equal "queued", waiter.status,
                     "premise: the dispatch parked behind the agent's own running turn"

        data = AiAgent::MessageBuilder.new(
          agent: @agent, context: holder.trigger_event_payload, original_comment: anchor
        ).build
        resolved = AiAgent::SessionContextResolver.new(
          agent: @agent, messages_data: data, system_prompt: "prompt"
        ).resolve
        DeliveryRecord.record!(holder, resolved)
        assert_includes DeliveryRecord.ids_in(holder.reload.trigger_event_payload), late.id,
                        "premise: the in-flight turn's window did swallow the waiter's comment"
        assert_equal "running", holder.reload.status,
                     "premise: and it has not ended, so its delivery is not settled"

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", waiter.reload.status,
                     "an agent holding a slot may not be promoted into a second turn, " \
                     "which is what keeps the refresh from deciding against an unsettled turn"
      end

      # The other half of the same invariant. Two turns run concurrently in one
      # topic only when they belong to different agents — TopicSlot again — and
      # delivered_comment_ids is scoped to this agent, so the record a promotion
      # reads is never a concurrent turn's.
      test "another agent's in-flight turn does not silence this agent's waiter" do
        topic_max!(2)
        holder_a = peer_agent("a")
        holder_b = peer_agent("b")
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        theirs = running_turn(anchor, agent: holder_a)
        assert_includes DeliveryRecord.ids_in(theirs.trigger_event_payload), late.id,
                        "premise: the other agent's window did carry this comment"
        second_slot = Task.create!(
          name: "Second slot", status: "running", trigger_event_name: "comment_created",
          agent: holder_b, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(anchor)
        )
        dispatch(late)
        waiter = tasks_for(@agent).where(status: "queued").sole

        second_slot.update!(status: "done")
        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        refute_equal "cancelled", waiter.reload.status,
                     "the record read at promotion is this agent's own, and this agent has none"
        refute_equal "queued", waiter.reload.status,
                     "premise: the freed slot really did promote it"
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
      # deleted underneath it, or the user pressed Stop. The comments it
      # swallowed were not deleted.
      #
      # Decided where the turn settles rather than where it was stopped: the
      # cancel is committed by another process while this turn is still inside
      # the provider call, so it cannot yet know whether the payload got there.
      test "a dropped dispatch comes back when the turn that was stopped settles" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        slot_holder(anchor)
        # The canceller: a request that loaded this row and wrote the status.
        Task.find(turn.id).update!(status: "cancelled")
        assert_empty restored_waiters,
                     "premise: the cancel does not decide for a turn still running"

        DeliveryRecord.restore_if_undelivered!(turn.reload)

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") }
      end

      # Control, and what scopes the declining to the turn it is about: a turn
      # paused for tool approval has already returned from its job, so nothing is
      # going to settle it later and everything it had to say is written. The
      # cancel decides for that one, as it always did.
      test "a dropped dispatch comes back when a paused turn is cancelled" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        turn.update!(status: "pending_approval")

        Task.find(turn.id).update!(status: "cancelled")

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "no worker is coming back for this one; the cancel is where it settles"
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

      # ─────────────────────────────────────────────
      # A restore that could not be made
      # ─────────────────────────────────────────────

      # Fail the enqueue for these comments and no others, the way a transient
      # queue or database failure would.
      def with_scheduler_failing_for(*comments, &block)
        ids = comments.map(&:id)
        real_new = Scheduler.method(:new)
        Scheduler.stub(:new, lambda { |context|
          raise ActiveRecord::ConnectionNotEstablished, "the queue is down" \
            if ids.include?(context.dig("comment", "id"))

          real_new.call(context)
        }, &block)
      end

      # The restore walks the orphans one at a time, and each is a dispatch of
      # its own. One that cannot be enqueued says nothing about the next.
      test "a dispatch that could not be enqueued does not take the others down with it" do
        anchor = comment("@#{@agent.name}: first")
        first_late = comment("@#{@agent.name}: second")
        second_late = comment("@#{@agent.name}: third")
        turn = running_turn(anchor)
        dispatch(first_late)
        dispatch(second_late)
        assert_equal [ first_late.id, second_late.id ],
                     DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload).sort,
                     "premise: both dispatches were dropped against this turn"

        slot_holder(anchor)
        with_scheduler_failing_for(first_late) { turn.update!(status: "failed") }

        assert_equal [ second_late.id ],
                     restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "one comment's failure is not the other comment's answer"
      end

      # And the turn's status is not the restore's to lose. The enqueues are
      # walked one at a time above, but the reads that decide *what* to enqueue
      # — re-reading the row, the sibling claims, the orphans' eligibility — are
      # not, and this fires from after_update_commit: an exception propagates
      # back into the update! that ended the turn, where AiAgentJob's rescue
      # answers it by writing `failed` over a turn that had finished and
      # answered.
      test "a restore that raises does not fail the turn" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)

        raiser = ->(_task) { raise ActiveRecord::ConnectionNotEstablished, "the database is down" }
        assert_nothing_raised do
          DeliveryRecord.stub(:restore!, raiser) { turn.update!(status: "failed") }
        end
        assert_empty restored_waiters, "premise: the restore really did not get through"
      end

      # Which leaves the comment on nothing at all: the callback runs after the
      # covering turn's status is committed, so there is no later transition
      # that would ask again. What was lost is only the asking — the drop record
      # is on the row and the orphan set is derived from it, so the restore is
      # reconstructible from that row at any later time.
      test "the sweep makes a restore the callback could not" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)

        with_scheduler_failing_for(late) { turn.update!(status: "failed") }
        assert_empty restored_waiters, "premise: the callback's restore did not get through"

        RestoreDroppedDispatchesJob.perform_now

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "the record is still on the row; only the asking was lost"
      end

      # Including for the ending whose status says the opposite. A turn whose
      # request never reached the provider finishes `done`, so the sweep has to
      # scan that status too and decide with the callback's predicate rather
      # than with the status alone.
      test "the sweep makes a restore the callback could not after a caught provider failure" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        DeliveryRecord.mark_handoff_failed!(turn)

        with_scheduler_failing_for(late) { turn.reload.update!(status: "done") }
        assert_empty restored_waiters, "premise: the callback's restore did not get through"

        RestoreDroppedDispatchesJob.perform_now

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") }
      end

      # Control: the sweep decides with that same predicate and not with
      # "terminal". A turn that delivered what it read owes nothing, and a sweep
      # reading `done` as an undelivered ending would answer every comment
      # dropped in its window a second time.
      test "the sweep restores nothing for a turn that delivered" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        turn.update!(status: "done")

        RestoreDroppedDispatchesJob.perform_now

        assert_empty restored_waiters,
                     "the agent read that comment and answered; there is nothing to restore"
      end

      # Every dispatch anchored on this comment, whatever became of it. Counting
      # only the queued ones cannot see a second restore: the new waiter
      # supersedes the first, which is cancelled on the way, so the queue holds
      # one row either way and two turns have been created for one comment.
      def dispatches_for(target)
        Task.where(agent: @agent, topic_id: @topic.id, creative_id: @creative.id).select do |t|
          t.trigger_event_payload.is_a?(Hash) &&
            t.trigger_event_payload.dig("comment", "id") == target.id
        end
      end

      # Control: the sweep runs over every undelivered ending in its window,
      # including the ones whose callback worked. What it re-reads is the orphan
      # set, and a dispatch that came back has a row of its own by then.
      test "the sweep does not restore a dispatch a second time" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        turn.update!(status: "failed")
        assert_equal 1, dispatches_for(late).count, "premise: the callback restored it"

        RestoreDroppedDispatchesJob.perform_now

        assert_equal 1, dispatches_for(late).count,
                     "the orphan set is re-read, and this comment has a row of its own by now"
      end

      # Control: a backstop with a horizon rather than a permanent second
      # opinion. A comment whose restore never got through and whose turn ended
      # long ago has been overtaken by whatever the topic did since.
      test "the sweep leaves a turn that ended before its window alone" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)

        with_scheduler_failing_for(late) { turn.update!(status: "failed") }
        Task.where(id: turn.id)
            .update_all(updated_at: (DeliveryRecord::RESTORE_SWEEP_WINDOW + 5.minutes).ago)

        RestoreDroppedDispatchesJob.perform_now

        assert_empty restored_waiters
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

      # Everything that labels the trigger moves with the anchor too, not just
      # the two keys ContextBuilder derives. Comment#dispatch_payload is the
      # declared single source of truth for what a comment_created dispatch
      # carries, and "from_ai" is the label AiAgentJob#record_loop_breaker_turn
      # reads: a re-anchor that drops it makes agent-to-agent work look
      # human-triggered, and the creative-retry breaker skips exactly that.
      test "re-anchoring keeps the metadata that labels the comment it moves onto" do
        anchor = comment("first")
        late = Comment.create!(
          creative: @creative, user: session_agent, topic: @topic,
          content: "second", quoted_comment_id: anchor.id, skip_dispatch: true
        )

        payload = TaskCoalescer.reanchor_payload(context_for(anchor), late)

        assert_equal true, payload.dig("comment", "from_ai"),
                     "the comment it moved onto was written by an agent"
        assert_equal anchor.id, payload.dig("comment", "quoted_comment_id")
      end

      # Control against carrying the old anchor's label across: the block is
      # rebuilt from the new comment, not merged onto the old one. A person's
      # comment must not inherit "from_ai" from the agent comment before it.
      test "re-anchoring onto a person's comment records it as theirs" do
        anchor = Comment.create!(
          creative: @creative, user: session_agent, topic: @topic,
          content: "first, from an agent", quoted_comment_id: comment("older").id, skip_dispatch: true
        )
        late = comment("second, from a person")
        # Built the way the ordinary door builds it, so the block being moved
        # off really does carry the label that must not survive the move.
        anchored = anchor.dispatch_payload.deep_stringify_keys
        assert_equal true, anchored.dig("comment", "from_ai"), "premise: the anchor was an agent's"

        payload = TaskCoalescer.reanchor_payload(anchored, late)

        assert_equal false, payload.dig("comment", "from_ai")
        assert_nil payload.dig("comment", "quoted_comment_id")
      end

      # The consequence, at the reader that pays for it: a restored turn on
      # another agent's comment is agent-to-agent work, and the loop breaker
      # only counts what it is told is not user-initiated.
      test "a restored agent-to-agent dispatch is counted by the loop breaker" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          config: { "loop_breaker_enabled" => true, "creative_retry_threshold" => 1 }
        )
        anchor = comment("@#{@agent.name}: first")
        late = Comment.create!(
          creative: @creative, user: session_agent, topic: @topic,
          content: "@#{@agent.name}: second", skip_dispatch: true
        )
        restored = DeliveryRecord.send(:restored_context, context_for(anchor), late)

        AiAgentJob.new.send(:record_loop_breaker_turn, @agent, restored)

        assert LoopBreaker.new(restored).check.should_break?,
               "the breaker counts a turn one agent started for another"
      end

      test "a restored dispatch is labelled with the author whose comment it answers" do
        anchor = comment("@#{@agent.name}: first")
        late = Comment.create!(
          creative: @creative, user: session_agent, topic: @topic,
          content: "@#{@agent.name}: second", skip_dispatch: true
        )
        turn = running_turn(anchor)
        dispatch(late)
        assert_includes DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload), late.id,
                        "premise: the dispatch was dropped, so only the restore can bring it back"

        slot_holder(anchor)
        turn.update!(status: "failed")

        assert_equal [ true ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "from_ai") }
      end

      def concurrency_saturated!
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: "User", scope_id: @agent.id,
          config: { "max_concurrent_jobs" => 1 }
        )
        ResourceTracker.for(@agent).reserve!("held")
      end

      def with_test_queue
        original = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        yield
      ensure
        ActiveJob::Base.queue_adapter = original
      end

      def restored_jobs
        ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == Collavre::AiAgentJob }
      end

      # The scheduler's decision is about now, and the restore happens a turn
      # later. A dispatch dropped while the agent was at its concurrency limit
      # carried a backoff; enqueuing it directly discards that, and the dying
      # turn's own ResourceTracker slot is still held when the callback fires.
      # So the restore asks the scheduler again rather than replaying a delay
      # decided at drop time.
      test "a restored dispatch takes the backoff the scheduler asks for" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        assert_includes DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload), late.id,
                        "premise: the dispatch was dropped, so only the restore can bring it back"
        concurrency_saturated!

        with_test_queue do
          turn.update!(status: "failed")

          assert_equal 1, restored_jobs.size, "the dispatch still comes back"
          assert restored_jobs.first[:at].present?,
                 "and waits out the delay the scheduler asked for rather than running now"
        end
      end

      # Control: with nothing to wait for, the restore is immediate — this is
      # what holds the change to the scheduler's answer rather than making
      # every restored dispatch wait.
      test "a restored dispatch with no pressure on it runs immediately" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        with_test_queue do
          turn.update!(status: "failed")

          assert_equal 1, restored_jobs.size
          assert_nil restored_jobs.first[:at]
        end
      end

      # The quota was fine when the dispatch was dropped and is exhausted by the
      # time it comes back. The existing rejection guard is at the drop door and
      # cannot see this one.
      test "a restore the scheduler now rejects is not enqueued past it" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        quota_exhausted!

        with_test_queue do
          turn.update!(status: "failed")

          assert_empty restored_jobs,
                       "restoring it would run work the quota check refuses right now"
        end
      end

      # ─────────────────────────────────────────────
      # A turn that was stopped after it handed over
      # ─────────────────────────────────────────────

      # `cancelled` is an undelivered ending only while the cancellation beat the
      # handoff. A user who presses Stop mid-answer stops a turn whose payload
      # the provider already has — AgentLifecycleManager keeps the partial reply
      # — and the comments that turn swallowed were read along with it.
      # Restoring them starts fresh agent work the moment the user asked for
      # none, and answers those comments a second time.
      #
      # And the record cannot be read by the cancel that stops the turn: Stop is
      # committed from a web request while the worker is still inside the
      # provider call, so the status callback fires a poll interval *before* the
      # turn writes down whether its payload got there. Asked at the settling
      # instead, which is the only moment either answer exists.
      test "a dispatch dropped against a turn stopped after the handoff is not restored" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        assert_includes DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload), late.id,
                        "premise: the dispatch was dropped against this turn"

        slot_holder(anchor)
        # The canceller, first: it has nothing to read yet.
        Task.find(turn.id).update!(status: "cancelled")
        assert_empty restored_waiters,
                     "the turn had not yet said whether its payload got there"

        # ...and then the turn's own teardown, which is where it says so.
        DeliveryRecord.mark_handed_off!(turn)
        DeliveryRecord.restore_if_undelivered!(turn.reload)

        assert_empty restored_waiters,
                     "the provider had that comment; re-dispatching it answers it twice"
      end

      # And the sweep decides with the same predicate, or the backstop undoes
      # what the callback correctly declined to do.
      test "the sweep restores nothing for a turn stopped after the handoff" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        Task.find(turn.id).update!(status: "cancelled")
        DeliveryRecord.mark_handed_off!(turn)

        RestoreDroppedDispatchesJob.perform_now

        assert_empty restored_waiters
      end

      # ─────────────────────────────────────────────
      # What the restore must ask again
      # ─────────────────────────────────────────────

      # The restore enqueues this agent by name, skipping Matcher#match — and
      # every routing path in #match is gated on feedback permission for the
      # creative. AiAgentJob re-asks the topic assignment and nothing else, so a
      # permission revoked between the drop and the restore would not be seen by
      # anybody.
      test "a dispatch is not restored to an agent that has lost permission on the creative" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)
        revoke_creative_permission!

        turn.update!(status: "failed")

        assert_empty restored_waiters,
                     "the agent may no longer read that creative, restore or not"
      end

      def revoke_creative_permission!
        CreativeShare.where(creative: @creative, user: @agent).destroy_all
        CreativeSharesCache.where(creative_id: @creative.id, user_id: @agent.id).destroy_all
      end

      # ─────────────────────────────────────────────
      # The claim that keeps the sweep off its own restore
      # ─────────────────────────────────────────────

      # AiAgentJob creates the Task row when it *runs*, so a restored job sitting
      # in the queue — a worker outage, a backlog longer than the sweep interval
      # — leaves the comment looking orphaned. Eventual Task creation cannot be
      # the idempotency marker for work that has not started yet.
      test "a restored dispatch still waiting in the queue is not enqueued again" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        with_test_queue do
          turn.update!(status: "failed")
          assert_equal 1, restored_jobs.size, "premise: the callback enqueued it"
          assert_empty dispatches_for(late), "premise: and no Task exists for it yet"

          RestoreDroppedDispatchesJob.perform_now

          assert_equal 1, restored_jobs.size,
                       "the dispatch is already on its way; a second one answers twice"
        end
      end

      # Control: the claim is taken for a dispatch that was enqueued, and given
      # back for one that was not. Otherwise this fix would be the previous
      # finding pointing the other way — a comment claimed by an enqueue that
      # never happened is a comment nobody ever comes back for.
      test "a restore whose enqueue failed is asked again by the sweep" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)
        slot_holder(anchor)

        with_enqueue_failing { turn.update!(status: "failed") }
        assert_empty restored_waiters, "premise: the enqueue really did not get through"

        RestoreDroppedDispatchesJob.perform_now

        assert_equal [ late.id ], restored_waiters.map { |t| t.trigger_event_payload.dig("comment", "id") },
                     "nothing was delivered, so nothing was claimed"
      end

      # Fail at the enqueue itself, past the scheduler — the transient queue
      # failure the claim is written before.
      def with_enqueue_failing(&block)
        raiser = ->(*) { raise ActiveRecord::ConnectionNotEstablished, "the queue is down" }
        Collavre::AiAgentJob.stub(:perform_later, raiser, &block)
      end
    end
  end
end
