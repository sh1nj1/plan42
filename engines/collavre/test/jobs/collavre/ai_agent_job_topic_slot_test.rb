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

    test "drops a scheduled job whose topic moved before task admission" do
      c = comment("scheduled before move")
      stale_context = context_for(c)
      destination = Creative.create!(description: "Moved destination", user: @user)
      Topics::TopicMove.new(topic: @topic, target_creative: destination).call
      matcher = Struct.new(:agent) do
        def assignment_permits?(_candidate)
          true
        end
      end.new(@agent)
      service_started = false

      Orchestration::Matcher.stub(:new, matcher) do
        AiAgentService.stub(:new, ->(*) { service_started = true }) do
          AiAgentJob.new.perform(@agent.id, "comment_created", stale_context)
        end
      end

      assert_not service_started
      assert_not Task.where(topic_id: @topic.id, creative_id: @creative.id).exists?
      assert_equal destination.id, @topic.reload.creative_id
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
      lock_relation = Struct.new(:sink, :record) do
        def find_by(id:)
          sink << id
          record
        end
      end.new(locked_topic_ids, @topic)

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
      lock_relation = Struct.new(:sink, :record) do
        def find_by(id:)
          sink << id
          record
        end
      end.new(locked_creative_ids, @creative)

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

    # The waiter and the notice that speaks for it commit in two steps —
    # park_waiter commits the row, post_waiting_notice posts its notice after —
    # so there is a window in which an opted-out waiter is queued with no
    # per-deferral notice naming it yet. Reading ownership off the surviving
    # notices inside that window classifies it as one the shared notice speaks
    # for and cancels it: the opt-out's turn is not deferred, it is discarded,
    # and no notice is left on screen to say a wait ever happened.
    #
    # Injected at waiting_reason_text — the call this door makes after its waiter
    # has committed and before the notice row exists — with the deletion running
    # through the real Comment#destroy rather than by calling the cancel path.
    test "deleting the shared notice spares an opt-out waiter whose own notice has not committed" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("coalescing")))

      shared = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                             waiting_notice_scope: Comment::WAITING_NOTICE_TOPIC).sole
      shared_waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole

      delete_shared_in_window = lambda do |*_args|
        parked = Task.where(agent: second_agent, topic_id: @topic.id, status: "queued").first
        if parked && Comment.exists?(shared.id)
          assert_not Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                                   waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                                   waiting_notice_task_id: parked.id).exists?,
                     "premise: the opt-out's own notice has not been posted yet"
          shared.destroy!
        end
        "another task is running"
      end

      Orchestration::AgentOrchestrator.stub :waiting_reason_text, delete_shared_in_window do
        AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(comment("opt-out")))
      end

      own_waiter = Task.where(agent: second_agent, topic_id: @topic.id).sole
      assert_equal "cancelled", shared_waiter.reload.status,
                   "premise: the shared notice did stop the waiter it stood for"
      assert_equal "queued", own_waiter.reload.status,
                   "the shared notice never spoke for an opted-out agent's waiter, committed notice or not"
    end

    # The other half of the same window: the waiter can be cancelled by a door
    # this fix does not touch — its anchor being deleted — while its notice
    # transaction is still open. What must not survive is a "task" notice naming a
    # task that has left the queue: a stop button for work that can no longer be
    # stopped, and one nothing collects, since a cancelled task is never promoted.
    test "no per-deferral notice survives a waiter cancelled while its notice was being posted" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("coalescing")))
      anchor = comment("opt-out")

      delete_anchor_in_window = lambda do |*_args|
        anchor.destroy! if Comment.exists?(anchor.id)
        "another task is running"
      end

      Orchestration::AgentOrchestrator.stub :waiting_reason_text, delete_anchor_in_window do
        AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(anchor))
      end

      own_waiter = Task.where(agent: second_agent, topic_id: @topic.id).sole
      assert_equal "cancelled", own_waiter.reload.status,
                   "premise: deleting the anchor cancelled the waiter mid-window"
      left_queue = Task.where.not(status: "queued").pluck(:id)
      assert_empty Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                                 waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                                 waiting_notice_task_id: left_queue).pluck(:id),
                   "a per-deferral notice for a task that has left the queue stops nothing"
    end

    # A waiter parked before the scope was recorded says nothing about which kind
    # of notice speaks for it. Keep those on the behaviour they were parked under
    # rather than guess: excluding them would leave an in-flight wait with no
    # stop control at all.
    test "a shared notice still cancels a queued waiter that recorded no notice scope" do
      shared, own_notice, _shared_waiter, own_waiter = mixed_notice_topic!
      Comment.where(id: own_notice.id).delete_all
      Task.where(id: own_waiter.id).update_all(waiting_notice_scope: nil)

      shared.destroy!

      assert_equal "cancelled", own_waiter.reload.status,
                   "nothing on the row says otherwise, so the old behaviour stands"
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

    # The waiter commits before its notice goes up, so the blocker can finish in
    # between and promote it. The drain guard asks the *shared* notice's
    # question — is anyone still waiting? — and another deferral parking in the
    # same burst answers yes, so a per-deferral notice goes up for a task that is
    # already running. Nothing removes it: cleanup_waiter_notice! ran during that
    # promotion, before this notice existed, and it is the only path that would.
    #
    # The promotion is injected at waiting_reason_text, the call this door makes
    # after its waiter has committed and before the guard takes the lock — the
    # exact window the report names — and runs through the real
    # dequeue_next_for_topic rather than flipping a status by hand.
    test "the late admission door posts no notice once its own waiter has been promoted" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      holder = occupy_slot!
      sibling = nil

      promote_in_window = lambda do |*args|
        # Another agent's deferral parks in the same burst, so the topic still
        # has a queued waiter when the guard asks.
        sibling ||= Task.create!(
          name: "Sibling waiter", status: "queued", trigger_event_name: "comment_created",
          agent: second_agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: context_for(comment("sibling"))
        )
        holder.update!(status: "done")
        AiAgentJob.stub :perform_later, ->(*) { nil } do
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
        end
        _reason_key, _topic_id, _creative_id = args
        "another task is running"
      end

      Orchestration::AgentOrchestrator.stub :waiting_reason_text, promote_in_window do
        AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("mine")))
      end

      waiter = Task.where(agent: @agent, topic_id: @topic.id).where.not(id: holder.id).sole
      assert_equal "pending", waiter.status, "the promotion took this waiter mid-window"
      assert_equal "queued", sibling.reload.status, "the sibling keeps the topic queue non-empty"
      assert_not Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                               waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                               waiting_notice_task_id: waiter.id).exists?,
                 "a notice for a promoted waiter is a stop button nothing can take down"
    end

    # …and the same question on the enqueue door, which posts its per-deferral
    # notice after park_waiter has already committed the row.
    test "the enqueue door posts no per-deferral notice for a waiter already promoted" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      c = comment("mine")
      orchestrator = Orchestration::AgentOrchestrator.new(
        event_name: "comment_created", context: context_for(c)
      )
      waiter = Task.create!(
        name: "Waiter", status: "pending", trigger_event_name: "comment_created",
        agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: context_for(c)
      )
      Task.create!(
        name: "Sibling waiter", status: "queued", trigger_event_name: "comment_created",
        agent: second_agent, topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: context_for(comment("sibling"))
      )

      orchestrator.send(:post_waiting_notice, @agent,
                        { timing: :deferred, reason: :topic_concurrency }, waiter: waiter)

      assert_not Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                               waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                               waiting_notice_task_id: waiter.id).exists?,
                 "the enqueue door has the same window between park_waiter and the notice"
    end

    # The control the two above need: a waiter that really is still queued gets
    # its notice, so this is not "stop posting per-deferral notices".
    test "the enqueue door still posts a per-deferral notice for a queued waiter" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      c = comment("mine")
      orchestrator = Orchestration::AgentOrchestrator.new(
        event_name: "comment_created", context: context_for(c)
      )
      waiter = Task.create!(
        name: "Waiter", status: "queued", trigger_event_name: "comment_created",
        agent: @agent, topic_id: @topic.id, creative_id: @creative.id,
        trigger_event_payload: context_for(c)
      )

      orchestrator.send(:post_waiting_notice, @agent,
                        { timing: :deferred, reason: :topic_concurrency }, waiter: waiter)

      assert Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                           waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                           waiting_notice_task_id: waiter.id).exists?,
             "a real wait still needs its own notice and stop button"
    end

    # A :delayed notice speaks for no waiter at all — it explains a rate-limited
    # or busy dispatch that is still going to run — so the waiter guard must not
    # be what decides whether it appears.
    test "a delayed notice is posted with no waiter to check" do
      c = comment("busy")
      orchestrator = Orchestration::AgentOrchestrator.new(
        event_name: "comment_created", context: context_for(c)
      )

      assert_difference -> {
        Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil)
               .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%").count
      }, 1 do
        orchestrator.send(:post_waiting_notice, @agent, { timing: :delayed, reason: :busy })
      end
    end

    # A per-deferral notice speaks for one waiter, and coalescing removes
    # waiters. Turning the policy on between two deferrals is enough: the first
    # parks with a notice of its own, the second folds it away, and nothing on
    # any path is left that would take that notice down — the fold does not, the
    # cancelled task will never be promoted through cleanup_waiter_notice!, and
    # the survivor keeps the topic queue non-empty so the drained sweep never
    # runs either.
    def folded_opt_out_waiter!
      policy = OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("first")))
      first = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      notice = Comment.find_by(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                               waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                               waiting_notice_task_id: first.id)
      assert notice, "premise: the opt-out door posts a notice naming this waiter"

      policy.update!(config: { "coalesce_pending_tasks" => true })
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("second")))

      survivor = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      assert_equal "cancelled", first.reload.status, "premise: the fold absorbed the first waiter"
      [ first, notice, survivor ]
    end

    test "folding a waiter takes down the per-deferral notice that spoke for it" do
      _first, notice, _survivor = folded_opt_out_waiter!

      assert_not Comment.exists?(notice.id),
                 "a notice for a folded waiter is a stop button nothing can take down"
    end

    # Stated as the invariant rather than as "this one row is gone", because
    # what makes the leftover worse than a duplicate line on screen is that its
    # stop button selects its own waiter by id and that waiter is no longer
    # queued — pressing it does nothing at all.
    test "no per-deferral notice outlives the waiter it speaks for" do
      folded_opt_out_waiter!

      stale = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                            waiting_notice_scope: Comment::WAITING_NOTICE_TASK)
                     .where.not(waiting_notice_task_id: Task.where(status: "queued").select(:id))
      assert_empty stale.to_a,
                   "a notice naming a waiter that has left the queue is a dead stop button"
    end

    # The controls the two above need. "Delete every notice in the fold" would
    # pass them both while stripping the survivor's own signal off the screen.
    test "folding leaves the surviving waiter's own notice standing" do
      _first, _notice, survivor = folded_opt_out_waiter!

      shared = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                             topic_concurrency_defer: true,
                             waiting_notice_scope: Comment::WAITING_NOTICE_TOPIC)
                      .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
                      .sole
      shared.destroy!
      assert_equal "cancelled", survivor.reload.status,
                   "the survivor keeps a notice that still stops it"
    end

    # …and it must reach only the waiters it actually folded. Another agent's
    # per-deferral notice is not this fold's to take down.
    test "folding does not touch another agent's per-deferral notice" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(comment("theirs")))
      theirs = Task.where(agent: second_agent, topic_id: @topic.id, status: "queued").sole
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("a")))
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("b")))

      assert_equal "queued", theirs.reload.status, "premise: only same-agent siblings fold"
      assert Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                           waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                           waiting_notice_task_id: theirs.id).exists?,
             "the opt-out agent's notice speaks for a waiter that is still queued"
    end

    # The fold is not the only way a waiter leaves the queue without ever being
    # promoted. Deleting the comment it answers cancels it through
    # Comment#cancel_pending_tasks, and that needs no policy change at all — the
    # opt-out on its own is enough.
    test "cancelling a waiter with its deleted anchor takes its notice down" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      anchor = comment("mine")
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(anchor))
      waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      notice = Comment.find_by(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                               waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                               waiting_notice_task_id: waiter.id)
      assert notice, "premise: the opt-out door posts a notice naming this waiter"

      anchor.destroy!

      assert_equal "cancelled", waiter.reload.status, "premise: the deleted prompt ended the turn"
      assert_not Comment.exists?(notice.id),
                 "the wait is over however it ended, so its dead stop button goes with it"
    end

    # The control: a waiter that survives the deletion keeps its notice. A
    # re-anchored task is still queued, so its stop button still stops something.
    test "re-anchoring a waiter onto an absorbed comment keeps its notice" do
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "coalesce_pending_tasks" => false }
      )
      occupy_slot!
      absorbed = comment("first")
      anchor = comment("second")
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(anchor))
      waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      waiter.update!(
        trigger_event_payload: waiter.trigger_event_payload.merge(
          Orchestration::TaskCoalescer::PAYLOAD_KEY => [ absorbed.id ]
        )
      )
      notice = Comment.find_by(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                               waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                               waiting_notice_task_id: waiter.id)
      assert notice, "premise: the opt-out door posts a notice naming this waiter"

      anchor.destroy!

      assert_equal "queued", waiter.reload.status, "premise: it re-anchored rather than cancelling"
      assert Comment.exists?(notice.id),
             "a waiter still in the queue keeps the notice that stops it"
    end

    # A shared notice and a per-deferral one coexist as soon as the agents in a
    # topic resolve the coalescing policy differently. Promoting the shared
    # notice's waiter deliberately keeps that notice up, because the opted-out
    # waiter still makes the topic queue non-empty — so when *that* waiter is
    # the one cancelled, the shared notice is left describing a wait that is
    # over, and no promotion will ever run the drained check for it.
    def stranded_shared_notice!(promote: true)
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: "User", scope_id: second_agent.id,
        config: { "coalesce_pending_tasks" => false }
      )
      holder = occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("mine")))
      AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(comment("theirs")))

      mine = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      theirs = Task.where(agent: second_agent, topic_id: @topic.id, status: "queued").sole
      shared = Comment.find_by(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                               waiting_notice_scope: Comment::WAITING_NOTICE_TOPIC)
      theirs_notice = Comment.find_by(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                                      waiting_notice_scope: Comment::WAITING_NOTICE_TASK,
                                      waiting_notice_task_id: theirs.id)
      assert shared, "premise: the coalescing agent's deferral posts a shared notice"
      assert theirs_notice, "premise: the opted-out agent's deferral posts its own"
      return [ shared, mine, theirs, theirs_notice ] unless promote

      holder.update!(status: "done")
      # Stubbed so the promoted turn does not run inline and drain the queue for
      # an ordinary reason — the state under test is one task promoted, one
      # still queued.
      AiAgentJob.stub :perform_later, ->(*) { nil } do
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
      end
      assert_equal "pending", mine.reload.status, "premise: the shared notice's waiter was promoted"
      assert_equal "queued", theirs.reload.status, "premise: the opted-out waiter is still parked"
      [ shared, mine, theirs, theirs_notice ]
    end

    # Two agents that both coalesce share one notice, so the survivor of a
    # promotion is a waiter the shared notice really does speak for.
    def coalescing_pair!
      holder = occupy_slot!
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(comment("mine")))
      AiAgentJob.new.perform(second_agent.id, "comment_created", context_for(comment("theirs")))

      mine = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      theirs = Task.where(agent: second_agent, topic_id: @topic.id, status: "queued").sole
      shared = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                             waiting_notice_scope: Comment::WAITING_NOTICE_TOPIC).sole
      assert_empty Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                                 waiting_notice_scope: Comment::WAITING_NOTICE_TASK),
                   "premise: neither deferral posted a per-deferral notice"
      [ holder, shared, mine, theirs ]
    end

    # The shared notice is dismissable, and dismissing it cancels the waiters it
    # speaks for — which is every queued waiter *except* those a per-deferral
    # notice claims. Once the promotion leaves nothing but claimed waiters
    # behind, that set is empty: the notice is a second "⏳" line on screen whose
    # stop button selects nothing, and the drained sweep will not collect it
    # because the claimed waiter keeps the topic queue non-empty.
    test "promotion takes down a shared notice left speaking for nobody" do
      shared, _mine, theirs, theirs_notice = stranded_shared_notice!

      assert_equal "queued", theirs.reload.status, "premise: a waiter is still parked"
      assert Comment.exists?(theirs_notice.id),
             "the waiter still queued keeps its own notice and its own stop button"
      assert_not Comment.exists?(shared.id),
                 "every waiter left is claimed by its own notice, so this one stops nothing"
    end

    # The control: a survivor that no per-deferral notice claims is exactly what
    # the shared notice is for. "Take it down on every promotion" would pass the
    # test above while stripping the wait/stop signal off a wait that is real.
    test "promotion keeps the shared notice for a waiter no other notice claims" do
      holder, shared, mine, theirs = coalescing_pair!

      holder.update!(status: "done")
      AiAgentJob.stub :perform_later, ->(*) { nil } do
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
      end

      assert_equal "pending", mine.reload.status, "premise: one waiter was promoted"
      assert_equal "queued", theirs.reload.status, "premise: the other is still parked"
      assert Comment.exists?(shared.id),
             "this notice is the only wait/stop signal the queued waiter has"
    end

    # Deleting a trigger cancels the waiter that answers it, and that waiter
    # never reaches a promotion — so nothing runs the drained check. With
    # coalescing on, the notice it leaves behind is the *shared* one, which
    # remove_waiter_notices! does not touch.
    test "deleting the last waiter's anchor takes down the shared notice" do
      occupy_slot!
      anchor = comment("mine")
      AiAgentJob.new.perform(@agent.id, "comment_created", context_for(anchor))
      waiter = Task.where(agent: @agent, topic_id: @topic.id, status: "queued").sole
      shared = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                             waiting_notice_scope: Comment::WAITING_NOTICE_TOPIC).sole

      anchor.destroy!

      assert_equal "cancelled", waiter.reload.status, "premise: deleting the prompt ended the wait"
      assert_not Comment.exists?(shared.id),
                 "nothing is queued behind it, so the notice describes a wait that is over"
    end

    # The control: the same deletion with another waiter still parked must leave
    # the notice alone — it speaks for that one too.
    test "deleting one anchor keeps the shared notice while another waiter is queued" do
      _holder, shared, mine, theirs = coalescing_pair!
      anchor = Comment.find(mine.trigger_event_payload.dig("comment", "id"))

      anchor.destroy!

      assert_equal "cancelled", mine.reload.status, "premise: that waiter's prompt is gone"
      assert_equal "queued", theirs.reload.status, "premise: the other is still parked"
      assert Comment.exists?(shared.id),
             "a wait that is still real keeps its notice and its stop button"
    end

    # The control: cancelling one waiter while another is still queued must not
    # take the shared notice down — that notice is still the only wait/stop
    # signal the remaining waiter has.
    test "cancelling one waiter keeps the shared notice while another is queued" do
      shared, mine, theirs, theirs_notice = stranded_shared_notice!(promote: false)

      theirs_notice.destroy!

      assert_equal "cancelled", theirs.reload.status
      assert_equal "queued", mine.reload.status, "premise: the shared notice still speaks for this"
      assert Comment.exists?(shared.id),
             "a wait that is still real keeps its notice and its stop button"
    end

    # …and it must not reach a :delayed notice. That one shares the "⏳" prefix
    # but explains a rate-limited or busy dispatch that is still going to run,
    # so an empty topic queue says nothing about whether it is still true.
    test "cancelling the last waiter leaves a delayed notice standing" do
      shared, _mine, _theirs, theirs_notice = stranded_shared_notice!
      orchestrator = Orchestration::AgentOrchestrator.new(
        event_name: "comment_created", context: context_for(comment("busy"))
      )
      orchestrator.send(:post_waiting_notice, @agent, { timing: :delayed, reason: :busy })
      delayed = Comment.where(creative_id: @creative.id, topic_id: @topic.id, user_id: nil,
                              topic_concurrency_defer: false)
                       .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%").sole

      theirs_notice.destroy!

      assert_equal 0, Task.where(topic_id: @topic.id, status: "queued").count,
                   "premise: the topic queue is empty"
      assert_not Comment.exists?(shared.id), "premise: the stranded shared notice came down"
      assert Comment.exists?(delayed.id),
             "a delayed dispatch is still going to run — an empty queue is not its question"
    end

    # The loop breaker counts the turns an agent takes for itself. A dispatch
    # the Scheduler judged :immediate can still lose the admission race here and
    # be parked instead — same turn, same burst — and the promotion that later
    # runs it enters the existing-Task branch, which records nothing either.
    test "records a deferred turn in the loop breaker" do
      Rails.cache.clear
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "creative_retry_threshold" => 2 }
      )
      occupy_slot!
      context = nil
      2.times do |i|
        context = agent_authored_context(comment("agent burst #{i}"))
        AiAgentJob.new.perform(@agent.id, "comment_created", context)
      end

      result = Orchestration::LoopBreaker.new(context).check

      assert result.should_break?,
             "two agent-authored turns were created here, so the threshold has been reached"
      assert_equal :creative_retry_exceeded, result.reason
    end

    # The control: LoopBreaker deliberately ignores user-initiated messages, and
    # deferring one must not start counting it. "Record every dispatch" would
    # pass the test above on its own.
    test "does not record a user-initiated deferred turn in the loop breaker" do
      Rails.cache.clear
      OrchestratorPolicy.create!(
        policy_type: "scheduling", scope_type: nil,
        config: { "creative_retry_threshold" => 2 }
      )
      occupy_slot!
      context = nil
      2.times do |i|
        context = context_for(comment("user burst #{i}"))
        AiAgentJob.new.perform(@agent.id, "comment_created", context)
      end

      assert Orchestration::LoopBreaker.new(context).check.safe?,
             "a person typing twice is not a loop"
    end

    def agent_authored_context(comment)
      context = context_for(comment)
      context.merge("comment" => context["comment"].merge("from_ai" => true))
    end

    # A cron scheduled against Main passes `topic_id: nil`, and the payload used
    # to repeat that nil while assign_main_topic had already filed the comment
    # under the real Main row. Before this branch that only made the dispatch
    # inconsistent; with admission the waiter is *queued* under `topic_id: nil`,
    # and promotion's refresh looks for comments in the task's own topic, finds
    # none there, and cancels the scheduled turn without delivering it.
    #
    # Driven through the payload CronActionJob actually sends rather than a
    # hand-built one, since the payload is where the two disagree.
    #
    # The occupancy bucket is keyed by that same nil, so the first cost is
    # upstream of the cancellation: the cron turn does not see the ordinary Main
    # turn holding the slot at all, and is admitted beside it.
    def occupied_main_cron_dispatch!
      main = @creative.main_topic(fallback_user: @user)
      holder = Task.create!(
        name: "Main holder", status: "running", trigger_event_name: "comment_created",
        agent: @agent, topic_id: main.id, creative_id: @creative.id,
        trigger_event_payload: { "topic" => { "id" => main.id } }
      )

      payload = nil
      SystemEvents::Dispatcher.stub(:dispatch, ->(_event, sent, **_options) { payload = sent; [] }) do
        CronActionJob.perform_now(
          creative_id: @creative.id, topic_id: nil,
          agent_id: @user.id, message: "@#{@agent.name}: scheduled check-in"
        )
      end

      AiAgentJob.new.perform(@agent.id, "comment_created", payload.deep_stringify_keys)

      cron_task = Task.where(agent: @agent, creative_id: @creative.id)
                      .where.not(id: holder.id).sole
      [ main, holder, cron_task ]
    end

    test "a Main-topic cron waits for the ordinary Main turn instead of running beside it" do
      main, _holder, cron_task = occupied_main_cron_dispatch!

      assert_equal "queued", cron_task.status,
                   "a cron turn must contend for the slot the Main topic already holds"
      assert_equal main.id, cron_task.topic_id,
                   "and wait in the topic its trigger was actually filed under"
    end

    test "a Main-topic cron turn is delivered rather than dropped on promotion" do
      _main, holder, waiter = occupied_main_cron_dispatch!
      assert_equal "queued", waiter.status, "premise: the cron turn parked behind the Main turn"

      holder.update!(status: "done")
      AiAgentJob.stub :perform_later, ->(*) { nil } do
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(waiter.topic_id, @creative.id)
      end

      assert_not_equal "cancelled", waiter.reload.status,
                       "the scheduled turn must be delivered, not silently dropped"
    end
  end
end
