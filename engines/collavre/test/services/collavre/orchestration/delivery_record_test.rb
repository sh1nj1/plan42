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

      # What the window actually swept up, read the same way the record reads it.
      def history_ids(resolved)
        Array(resolved[:messages] || resolved["messages"]).filter_map do |message|
          next unless (message[:kind] || message["kind"]).to_s == "chat_history"

          (message[:comment_id] || message["comment_id"])&.to_i
        end
      end

      # The text the window rendered, regardless of whether the entry claims to
      # carry its comment whole. Premises about *what the window swept up* are
      # asserted here rather than through history_ids, which reads the claim.
      def history_texts(resolved)
        Array(resolved[:messages] || resolved["messages"]).filter_map do |message|
          next unless (message[:kind] || message["kind"]).to_s == "chat_history"

          Array(message[:parts] || message["parts"]).map { |p| p[:text] || p["text"] }.join
        end
      end

      def kinds_in(resolved)
        Array(resolved[:messages] || resolved["messages"]).map { |m| (m[:kind] || m["kind"]).to_s }
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

      # A history entry is text and nothing else — MessageBuilder attaches blobs
      # only on the trigger. So a comment carrying an image that the window swept
      # up has been *partly* delivered, and the record's predicate is false for
      # it. Recording it would discard the one dispatch that would have carried
      # the image; an image-only comment would reach the agent as a blank line.
      test "a comment whose image the history window left behind is not recorded" do
        anchor = comment("first")
        turn = task_for(anchor)
        illustrated = comment("look at this")
        illustrated.images.attach(
          io: File.open(Collavre::Engine.root.join("test/fixtures/files/small.png")),
          filename: "small.png", content_type: "image/png"
        )

        resolved = resolved_for(turn, @agent)
        assert history_texts(resolved).any? { |t| t.include?("look at this") },
               "premise: the window did sweep it up, as text"

        DeliveryRecord.record!(turn, resolved)

        assert_not_includes recorded(turn), illustrated.id,
                            "its image was never handed over, so it was not delivered"
        assert_nil DeliveryRecord.covering_task(@agent, illustrated.id, context_for(anchor), "comment_created"),
                   "and its own dispatch is the only thing that would carry the image"
      end

      # The same rule as the image, and the second thing it catches. A comment
      # linking a creative brings that creative's rendered subtree with it —
      # but only through append_referenced_creative_contexts, which scans the
      # anchor and the merged blocks and never the history window. So the
      # covering turn renders the link *text* and none of what it points at,
      # and the dispatch that would have supplied it is the one being dropped.
      test "a comment whose linked creative the history window left behind is not recorded" do
        other = Creative.create!(description: "Spec the agent needs", user: @user)
        anchor = comment("first")
        turn = task_for(anchor)
        linked = comment("answer using [Spec](/creatives/#{other.id})")

        resolved = resolved_for(turn, @agent)
        assert history_texts(resolved).any? { |t| t.include?("/creatives/#{other.id}") },
               "premise: the window did sweep it up, as link text"
        assert_not_includes kinds_in(resolved), "referenced_creative",
                            "premise: and the turn injected no subtree for it"

        DeliveryRecord.record!(turn, resolved)

        assert_not_includes recorded(turn), linked.id,
                            "the creative it points at was never handed over"
        assert_nil DeliveryRecord.covering_task(@agent, linked.id, context_for(anchor), "comment_created"),
                   "and its own dispatch is the only thing that would supply that subtree"
      end

      # ...and the filter is tied to what the turn was missing, not to links.
      # A link to a creative already in context — the topic's own, most often —
      # points at a subtree the agent was handed before the window ran, so the
      # history entry does carry that comment whole.
      test "a comment linking a creative already in context is recorded" do
        anchor = comment("first")
        turn = task_for(anchor)
        linked = comment("as in [this one](/creatives/#{@creative.id})")

        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_includes recorded(turn), linked.id,
                        "nothing was withheld, so the turn delivered it"
      end

      # Same rule, the other way a link supplies nothing:
      # append_referenced_creative_contexts skips an id with no creative behind
      # it, so a turn anchored on this comment would render exactly what the
      # window rendered and the entry does carry it whole.
      test "a comment linking a creative that no longer exists is recorded" do
        gone = Creative.create!(description: "deleted before the turn ran", user: @user)
        gone_id = gone.id
        anchor = comment("first")
        turn = task_for(anchor)
        linked = comment("see [that](/creatives/#{gone_id})")
        gone.destroy!

        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_includes recorded(turn), linked.id,
                        "there was no subtree to withhold"
      end

      # The record is written by whichever pass assembles, and merged onto the
      # payload the caller loaded — but a drop is written by a *refused*
      # dispatch, in another process, after that load. A resumed turn that
      # rewrites the whole JSON from its own stale copy erases the drop, and the
      # comment it discarded has nothing left to bring it back.
      test "a drop claimed while the turn was assembling survives the record" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assembling = Task.find(turn.id)
        assert DeliveryRecord.claim_drop!(Task.find(turn.id), late.id), "premise: another process refused a dispatch"

        later_still = comment("third")
        DeliveryRecord.record!(assembling, resolved_for(assembling, @agent))

        assert_equal [ late.id ], DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload),
                     "the record must not overwrite a drop it never saw"
        assert_includes recorded(turn), later_still.id,
                        "and the second pass still records what it swallowed"
      end

      # Reading a comment and discarding a dispatch for it are different facts,
      # and only the second one is a thing to put back. The history record
      # answers "has the agent been given this?" — a question the topic's whole
      # burst answers yes to, including comments this agent was never matched
      # for. What the restore owes is narrower: the dispatches it actually
      # refused.
      test "reading a comment is not by itself a dropped dispatch" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert_includes recorded(turn), late.id, "premise: the turn read it"
        assert_empty DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload),
                     "but no dispatch was ever refused, so there is nothing to restore"
      end

      test "a claimed drop is recorded against the covering turn" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        assert DeliveryRecord.claim_drop!(turn, late.id), "the turn is in flight and may take the drop"
        assert_equal [ late.id ], DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload)
      end

      # The drop and the record are one act. A turn that ends between the caller
      # reading it and the drop being written has already run its restore, so a
      # record written afterwards is a comment nobody ever comes back for. The
      # caller is told no and dispatches normally instead.
      test "a turn that has ended cannot take a drop" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))

        Task.where(id: turn.id).update_all(status: "failed")

        assert_not DeliveryRecord.claim_drop!(turn, late.id),
                   "the caller's snapshot said running; the row says otherwise"
        assert_empty DeliveryRecord.dropped_ids_in(turn.reload.trigger_event_payload)
      end

      # The dispatch door and the promotion door have to mean the same thing by
      # "this turn delivered nothing". Promotion expresses it by leaving a
      # status out of DELIVERED_STATUSES; the dispatch door expresses it by
      # restoring on that status. A status added to one list and not the other
      # is how the two doors come to disagree.
      test "the statuses that restore are exactly the terminal ones promotion calls undelivered" do
        terminal = %w[done failed cancelled escalated]

        assert_equal (terminal - AgentOrchestrator::DELIVERED_STATUSES).sort,
                     DeliveryRecord::UNDELIVERED_TERMINAL_STATUSES.sort
      end

      # The turn-level flag cannot answer for a turn that ran twice, so the
      # handoff also writes down what it carried. A resumed attempt reads
      # comments that landed during the pause, and those the first handoff did
      # not carry — the record has to grow with each attempt that lands, not be
      # written once and left.
      test "the handoff records the comments the attempt carried, and grows with a second one" do
        anchor = comment("first")
        turn = task_for(anchor)
        late = comment("second")
        DeliveryRecord.record!(turn, resolved_for(turn, @agent))
        DeliveryRecord.mark_handed_off!(turn.reload)

        assert_equal [ late.id ],
                     DeliveryRecord.handed_off_ids_in(turn.reload.trigger_event_payload)

        during_pause = comment("third")
        DeliveryRecord.record!(turn.reload, resolved_for(turn.reload, @agent))
        assert_equal [ late.id ],
                     DeliveryRecord.handed_off_ids_in(turn.reload.trigger_event_payload),
                     "reading it is not handing it over"

        DeliveryRecord.mark_handed_off!(turn.reload)

        assert_equal [ late.id, during_pause.id ].sort,
                     DeliveryRecord.handed_off_ids_in(turn.reload.trigger_event_payload)
      end

      # The same drift, on the other list. TURN_SCOPED_KEYS is what a restored
      # dispatch is stripped of, and it is right only while it names every key a
      # turn writes onto its own payload. Driving every writer over one
      # payload is what makes another one added later show up here rather than as a
      # restored dispatch quietly carrying it.
      test "the stripped keys are exactly the ones a turn writes onto its own payload" do
        anchor = comment("first")
        late = comment("second")
        folded = comment("third")
        turn = task_for(anchor)
        dispatched = turn.trigger_event_payload.keys

        DeliveryRecord.record!(turn, resolved_for(turn, @agent))
        DeliveryRecord.claim_drop!(turn.reload, late.id)
        DeliveryRecord.mark_handoff_failed!(turn.reload)
        DeliveryRecord.mark_handed_off!(turn.reload)
        DeliveryRecord.claim_restore!(turn.reload, late.id)
        turn.update!(
          trigger_event_payload: TaskCoalescer.reanchor_payload(
            TaskCoalescer.absorb_into_payload(turn.reload.trigger_event_payload, [ folded.id ]),
            late
          )
        )

        written = turn.reload.trigger_event_payload.keys - dispatched
        assert_equal DeliveryRecord::TURN_SCOPED_KEYS.sort, written.sort
      end
    end
  end
end
