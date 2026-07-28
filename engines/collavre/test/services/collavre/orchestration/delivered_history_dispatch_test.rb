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
      test "the restored dispatch carries none of the dead turn's bookkeeping" do
        anchor = comment("@#{@agent.name}: first")
        late = comment("@#{@agent.name}: second")
        turn = running_turn(anchor)
        dispatch(late)

        slot_holder(anchor)
        turn.update!(status: "failed")

        payload = restored_waiters.sole.trigger_event_payload
        assert_empty DeliveryRecord.ids_in(payload)
        assert_empty Array(payload[TaskCoalescer::PAYLOAD_KEY])
        assert_nil payload[TaskCoalescer::ACQUIRED_ANCHOR_KEY]
        assert_equal late.content, payload.dig("chat", "content"),
                     "and it is anchored on the comment it was dispatched for"
      end
    end
  end
end
