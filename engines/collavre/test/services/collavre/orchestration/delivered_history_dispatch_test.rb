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
    end
  end
end
