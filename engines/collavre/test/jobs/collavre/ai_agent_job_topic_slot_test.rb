# frozen_string_literal: true

require "test_helper"

module Collavre
  # The Scheduler's topic-concurrency check counts Task rows, but for an
  # :immediate decision that row is only created inside AiAgentJob. A burst of
  # comments dispatched before the first job runs therefore all see an empty
  # topic and are all judged :immediate — several turns run at once in a topic
  # limited to one. AiAgentJob re-checks at row-creation time.
  class AiAgentJobTopicSlotTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @creative = creatives(:tshirt)
      @agent = users(:ai_bot)
      @topic = Topic.create!(name: "Slot topic", creative: @creative, user: @user)
      Orchestration::ResourceTracker.for(@agent).reset!
    end

    teardown do
      Orchestration::ResourceTracker.for(@agent).reset!
    end

    def context_for(comment)
      {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => @topic.id },
        "sender" => { "id" => @user.id, "name" => @user.name },
        "comment" => { "id" => comment.id, "content" => comment.content, "user_id" => @user.id }
      }
    end

    def comment(body)
      Comment.create!(
        creative: @creative, user: @user, topic: @topic, content: body, skip_dispatch: true
      )
    end

    # A second, independent agent — the shape topic_max > 1 actually serves.
    def second_agent
      @second_agent ||= Collavre::User.create!(
        name: "slot-agent-2",
        email: "slot2-#{SecureRandom.hex(4)}@agent.test",
        password: "password123",
        llm_vendor: "openai",
        llm_model: "gpt-4",
        system_prompt: "You are a second agent."
      )
    end

    def occupy_slot!(status: "running")
      Task.create!(
        name: "Holder", status: status, trigger_event_name: "comment_created",
        agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: { "topic" => { "id" => @topic.id } }
      )
    end

    test "queues a waiter instead of starting a second turn in an occupied topic" do
      occupy_slot!
      c = comment("late arrival")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued")
      assert_equal 1, waiters.count
      assert_equal c.id, waiters.first.trigger_event_payload.dig("comment", "id")
      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "running").count,
                   "the holder must remain the only running task"
    end

    # pending / pending_approval hold the slot too: pending is claimed but not
    # started, pending_approval is paused and does not drain the queue.
    test "treats a pending_approval holder as occupying the slot" do
      occupy_slot!(status: "pending_approval")
      c = comment("late arrival")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count
    end

    test "coalesces the late waiter with one already parked" do
      occupy_slot!
      first = comment("first")
      second = comment("second")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(first))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(second))

      waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued")
      assert_equal 1, waiters.count
      assert_equal second.id, waiters.first.trigger_event_payload.dig("comment", "id")
      assert_equal [ first.id ],
                   waiters.first.trigger_event_payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]
    end

    test "posts one waiting notice for the deferred burst" do
      occupy_slot!
      2.times { |i| AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("m#{i}"))) }

      notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
                       .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
      assert_equal 1, notices.count
    end

    # With coalescing off there is no survivor to speak for the burst: every
    # deferral keeps its own waiter. A single deduplicated notice over N
    # independent waiters is then a stop button that cancels other people's
    # work — Comment#cancel_queued_tasks_for_waiting_notice reads "no sibling
    # notice left" as "this one stood for the whole topic".
    test "the late admission door keeps one notice per waiter when coalescing is off" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      3.times { |i| AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("m#{i}"))) }

      notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                              topic_concurrency_defer: true)
                       .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
                       .order(:id).to_a
      assert_equal 3, notices.size, "the opt-out posts one notice per deferral on this door too"
      assert_equal 3, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count

      notices.last.destroy!

      assert_equal 2, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "a notice that was never deduplicated speaks for one waiter only"
    end

    # The notice is only ever removed by the promotion that drains this topic's
    # queue. If the blocker finishes between the waiter's commit and this call,
    # that promotion has already run its cleanup — a notice posted afterwards
    # explains a wait nobody is doing and nothing will ever take it down.
    test "posts no waiting notice once the queue has already drained" do
      notices = -> {
        Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
               .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%").count
      }

      assert_no_difference notices do
        Orchestration::AgentOrchestrator.post_topic_concurrency_notice(@creative.id, @topic.id)
      end
    end

    test "posts the waiting notice while a waiter is still queued" do
      occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("m")))

      assert Task.queued_for_topic(@topic.id, @creative.id).exists?
      assert Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
                    .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%").exists?,
             "a real wait must still be explained"
    end

    test "runs normally when the topic slot is free" do
      c = comment("first in topic")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      assert_equal 0, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "an empty topic must not defer"
      assert Task.where(agent: @agent, topic_id: @topic.id).exists?,
             "a task should have been created and executed"
    end

    test "does not defer when the context carries no topic" do
      c = Comment.create!(creative: @creative, user: @user, content: "no topic", skip_dispatch: true)
      context = {
        "creative" => { "id" => @creative.id },
        "comment" => { "id" => c.id, "content" => c.content, "user_id" => @user.id }
      }

      AiAgentJob.new.perform(@agent.id, "comment_created", context)

      assert_equal 0, Task.where(agent: @agent, status: "queued").count
    end

    # coalesce_pending_tasks governs whether waiters are FOLDED, not whether
    # topic_max_concurrent_jobs is enforced. Turning it off must still keep the
    # topic to one turn at a time — otherwise a burst dispatched before the first
    # job materializes a task starts one concurrent turn per comment.
    test "policy disables folding but not topic admission" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      first = comment("first")
      second = comment("second")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(first))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(second))

      waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").order(:id)
      assert_equal 2, waiters.count, "with coalescing off each comment keeps its own waiter"
      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "running").count,
                   "the holder must still be the only running task"
      assert_nil waiters.first.trigger_event_payload[Orchestration::TaskCoalescer::PAYLOAD_KEY]
    end

    # topic_max > 1 exists to run *different* agents in parallel. An agent that
    # already has a turn in flight must not take a second slot: TaskCoalescer
    # only folds `queued` rows, so two concurrent turns can never be merged.
    test "defers an agent that already holds a slot even when the topic has room" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "topic_max_concurrent_jobs" => 2 }
      )
      occupy_slot!
      c = comment("same agent again")

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))

      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "the agent's second turn must queue behind its own running one"
      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "running").count
    end

    test "a second agent still takes the free slot when the topic has room" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "topic_max_concurrent_jobs" => 2 }
      )
      occupy_slot!
      other = second_agent
      Orchestration::ResourceTracker.for(other).reset!
      c = comment("different agent")

      AiAgentJob.new.perform(other.id, "comment_created", context_for(c))

      assert_equal 0, Task.where(agent: other, topic_id: @topic.id, status: "queued").count,
                   "the parallelism topic_max > 1 buys must survive the same-agent guard"
      assert Task.where(agent: other, topic_id: @topic.id).exists?
    ensure
      Orchestration::ResourceTracker.for(other).reset! if other
    end

    # The occupancy count and the row that claims the slot have to be one step.
    # Two workers starting in the same millisecond otherwise both read a free
    # slot before either inserts — the TOCTOU race this check exists to close.
    test "admission counts and claims the slot inside one locked transaction" do
      locked_topic_ids = []
      lock_relation = Struct.new(:sink) do
        def find_by(id:)
          sink << id
          nil
        end
      end.new(locked_topic_ids)

      # The suite already runs inside a transaction, so `transaction_open?` is
      # always true — compare the nesting depth against the ambient one instead.
      baseline_depth = Task.connection.open_transactions
      check_depth = nil
      counting_scope = Task.occupying_topic_slot(@topic.id, @creative.id)
      c = comment("first in topic")

      Topic.stub(:lock, lock_relation) do
        Task.stub(:occupying_topic_slot, ->(*) {
          check_depth ||= Task.connection.open_transactions
          counting_scope
        }) do
          AiAgentJob.new.perform(@agent.id, "comment_created", context_for(c))
        end
      end

      # The admitted task drains the topic queue as it finishes, and that claim
      # takes the same lock — one entry per claim attempt, none skipping it.
      assert_equal [ @topic.id ], locked_topic_ids.uniq,
                   "admission must serialize on the topic row"
      assert_predicate locked_topic_ids, :any?
      assert_operator check_depth, :>, baseline_depth,
                      "the occupancy check must run inside the claiming transaction"
    end

    # A creative's Main topic carries topic.id == nil (Scheduler covers this
    # shape). It is still subject to topic_max_concurrent_jobs — occupancy is
    # counted with topic_id: nil scoped to the creative — so it needs a lock too.
    # Without one there is no shared row to serialize on and concurrent workers
    # both read a free slot before either inserts.
    test "admission on the Main topic serializes on the creative row" do
      locked_creative_ids = []
      lock_relation = Struct.new(:sink) do
        def find_by(id:)
          sink << id
          nil
        end
      end.new(locked_creative_ids)

      baseline_depth = Task.connection.open_transactions
      check_depth = nil
      counting_scope = Task.occupying_topic_slot(nil, @creative.id)
      c = Comment.create!(creative: @creative, user: @user, content: "main topic", skip_dispatch: true)
      main_context = {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => nil },
        "comment" => { "id" => c.id, "content" => c.content, "user_id" => @user.id }
      }

      Creative.stub(:lock, lock_relation) do
        Task.stub(:occupying_topic_slot, ->(*) {
          check_depth ||= Task.connection.open_transactions
          counting_scope
        }) do
          AiAgentJob.new.perform(@agent.id, "comment_created", main_context)
        end
      end

      assert_equal [ @creative.id ], locked_creative_ids.uniq,
                   "Main-topic admission must serialize on a stable creative-scoped row"
      assert_predicate locked_creative_ids, :any?
      assert_operator check_depth, :>, baseline_depth,
                      "the occupancy check must run inside the claiming transaction"
    end

    test "defers a Main-topic dispatch when the creative's Main slot is taken" do
      Task.create!(
        name: "Main holder", status: "running", trigger_event_name: "comment_created",
        agent: @agent, topic_id: nil, creative_id: @creative.id,
        trigger_event_payload: { "topic" => { "id" => nil } }
      )
      c = Comment.create!(creative: @creative, user: @user, content: "main late", skip_dispatch: true)
      main_context = {
        "creative" => { "id" => @creative.id },
        "topic" => { "id" => nil },
        "comment" => { "id" => c.id, "content" => c.content, "user_id" => @user.id }
      }

      AiAgentJob.new.perform(@agent.id, "comment_created", main_context)

      assert_equal 1, Task.where(agent: @agent, topic_id: nil, creative_id: @creative.id,
                                 status: "queued").count
    end

    # The promoted task holds the slot as `pending` until this job starts, and a
    # comment arriving in that gap parks a waiter that enqueue-time coalescing
    # cannot fold into a non-`queued` sibling. Execution is the last moment both
    # turns are still un-started, so the fold has to run here.
    test "folds a waiter parked between promotion and execution" do
      claimed = Task.create!(
        name: "Response to comment_created", status: "pending",
        trigger_event_name: "comment_created", agent: @agent,
        topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: context_for(comment("@#{@agent.name}: first"))
      )
      late = comment("@#{@agent.name}: and also this")
      late_waiter = Task.create!(
        name: "Response to comment_created", status: "queued",
        trigger_event_name: "comment_created", agent: @agent,
        topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: context_for(late)
      )

      fake_service = -> { "" }
      AiAgentService.stub :new, ->(_task) { fake_service } do
        AiAgentJob.new.perform(claimed)
      end

      assert_equal "cancelled", late_waiter.reload.status,
                   "both comments were un-started — they belong to one turn"
      assert_equal late.id, claimed.reload.trigger_event_payload.dig("comment", "id")
    end

    # Coalescing folds *same-agent* siblings, so a User-scoped scheduling policy
    # is where an administrator turns it off for one agent without touching the
    # others in the topic. PolicyResolver#scheduling_config excludes agent
    # policies by construction, so asking it was the same as ignoring the opt-out.
    test "a User-scoped policy turns folding off for that agent" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: @agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("first")))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("second")))

      assert_equal 2, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "an agent-scoped opt-out must reach the folding decision"
    end

    # …and only for that agent. A fix that simply stopped folding would pass the
    # test above on its own.
    test "a User-scoped opt-out leaves the other agents in the topic folding" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!

      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("first")))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("second")))

      assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                   "another agent's opt-out must not switch folding off for this one"
    end

    # A mixed topic — one agent coalescing, one opted out — has both kinds of
    # notice standing at once. Classifying a notice by whether a sibling survives
    # then reads the shared one as a per-deferral one and cancels the newest
    # queued waiter, which is the one the *other* notice speaks for.
    def mixed_notice_topic!
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("a")))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("b")))
      AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(comment("c")))

      notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                              topic_concurrency_defer: true)
                       .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
                       .order(:id).to_a
      assert_equal 2, notices.size,
                   "the coalescing agent shares one notice; the opt-out posts its own"

      [ notices.first, notices.last,
        Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole,
        Task.where(agent: second_agent, topic_id: @topic.id, status: "queued").sole ]
    end

    # The dedup guard asks whether the topic already has *its* one notice. An
    # opt-out notice is not that notice, so letting it answer would leave the
    # coalescing agent's waiter with nothing on screen whenever an opted-out
    # agent happened to defer into the topic first.
    test "a per-deferral notice does not suppress the topic's shared notice" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!

      AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(comment("opt-out first")))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("coalescing second")))

      scopes = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                             topic_concurrency_defer: true)
                      .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
                      .order(:id).pluck(:waiting_notice_scope)
      assert_equal [ Comment::WAITING_NOTICE_TASK, Comment::WAITING_NOTICE_TOPIC ], scopes,
                   "the coalescing agent's waiter needs a notice of the topic's own"
    end

    test "deleting the shared notice cancels the waiter it stood for, not the opt-out's" do
      shared, _own_notice, shared_waiter, own_waiter = mixed_notice_topic!

      shared.destroy!

      assert_equal "cancelled", shared_waiter.reload.status,
                   "the shared notice is the only stop control its waiter has"
      assert_equal "queued", own_waiter.reload.status,
                   "a waiter whose own notice is still on screen was never this one's to cancel"
    end

    # A per-deferral notice speaks for one waiter, so promoting that waiter ends
    # what it describes. The drained guard is the *shared* notice's question: with
    # the opt-out and a second waiter still parked, it keeps every notice up —
    # including one offering a stop button for a task that is already running.
    test "promoting an opt-out waiter takes its own notice down and leaves the others" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      holder = occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("a")))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("b")))
      notices = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                              topic_concurrency_defer: true)
                       .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
                       .order(:id).to_a
      waiters = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").order(:id).to_a
      assert_equal [ 2, 2 ], [ notices.size, waiters.size ]

      holder.update!(status: "done")
      # Promotion only: without this the promoted job runs inline, finishes, and
      # drains the queue, which is the case the drained guard already covers.
      AiAgentJob.stub :perform_later, ->(*) { nil } do
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
      end

      assert_equal "pending", waiters.first.reload.status, "the oldest waiter is the promoted one"
      assert_equal "queued", waiters.last.reload.status, "the second waiter is still waiting"
      assert_not Comment.exists?(notices.first.id),
                 "the promoted waiter's own notice describes a wait that is over"
      assert Comment.exists?(notices.last.id),
             "the waiter still queued keeps the notice that speaks for it"
    end

    test "deleting a per-deferral notice cancels only its own waiter" do
      _shared, own_notice, shared_waiter, own_waiter = mixed_notice_topic!

      own_notice.destroy!

      assert_equal "cancelled", own_waiter.reload.status
      assert_equal "queued", shared_waiter.reload.status,
                   "the opt-out's 1:1 must not reach across to the coalescing agent"
    end
  end
end
