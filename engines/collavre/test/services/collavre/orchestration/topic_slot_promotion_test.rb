# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    # Admission (AiAgentJob) and promotion (dequeue_next_for_topic) are two ways
    # into the same topic slot. Guarding only admission leaves the promotion path
    # free to hand a slot to an agent that already holds one, or to overfill a
    # topic outright — and TaskCoalescer folds only `queued` rows, so two
    # concurrent turns for one agent can never be merged after the fact.
    class TopicSlotPromotionTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = Topic.create!(name: "Promotion topic", creative: @creative, user: @user)
      end

      def other_agent(tag)
        Collavre::User.create!(
          name: "promo-agent-#{tag}",
          email: "promo-#{tag}-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are agent #{tag}."
        )
      end

      def payload_for(comment)
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

      def task_for(agent, status:, comment: nil)
        Task.create!(
          name: "Task #{status}", status: status, trigger_event_name: "comment_created",
          agent: agent, topic_id: @topic.id, creative_id: @creative.id,
          trigger_event_payload: payload_for(comment || self.comment("trigger"))
        )
      end

      # A promoted waiter leaves "queued" for good: the test adapter runs its
      # AiAgentJob inline, so it can be anywhere from "pending" to "done" by the
      # time control returns. What matters is that it was let out of the queue.
      def assert_promoted(task, message)
        assert_includes %w[pending running delegated done], task.reload.status, message
      end

      def topic_max!(value)
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "topic_max_concurrent_jobs" => value }
        )
      end

      # topic_max = 1, a live holder, and a waiter behind it. Promotion runs on
      # every terminal task in the topic, including tasks that never held this
      # slot, so it has to re-check occupancy rather than trust its caller.
      test "does not promote a waiter while the topic is at capacity" do
        holder = task_for(other_agent("holder"), status: "running")
        waiter = task_for(@agent, status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", waiter.reload.status,
                     "a full topic must not admit a second turn through the promotion path"
        assert_equal "running", holder.reload.status
      end

      # topic_max = 2 exists to run *different* agents in parallel. An agent with
      # a turn already in flight must stay queued even though the topic has room.
      test "does not promote a waiter whose agent already occupies a slot" do
        topic_max!(2)
        task_for(@agent, status: "running")
        waiter = task_for(@agent, status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", waiter.reload.status,
                     "the same agent must not run two concurrent turns in one topic"
      end

      test "promotes a different agent's waiter into the free slot" do
        topic_max!(2)
        task_for(@agent, status: "running")
        waiter = task_for(other_agent("second"), status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_promoted waiter, "the parallelism topic_max > 1 buys must survive the eligibility guard"
      end

      # The oldest waiter is not always the eligible one. Skipping it entirely
      # would strand every waiter behind a busy agent.
      test "skips an ineligible waiter and promotes the next eligible one" do
        topic_max!(2)
        task_for(@agent, status: "running")
        blocked = task_for(@agent, status: "queued")
        eligible = task_for(other_agent("third"), status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_equal "queued", blocked.reload.status
        assert_promoted eligible, "an eligible waiter behind a blocked one must still run"
      end

      # A deferral is not proof that the topic is full: with topic_max > 1 an
      # agent defers because *it* is busy, while a slot sits free for someone
      # else. Draining only when every occupant is gone strands that waiter until
      # the unrelated holder finishes.
      test "drains another agent's waiter when a slot remains free after deferring" do
        topic_max!(2)
        Orchestration::ResourceTracker.for(@agent).reset!
        task_for(@agent, status: "running")
        stranded = task_for(other_agent("waiting"), status: "queued")

        AiAgentJob.new.perform(@agent.id, "comment_created", payload_for(comment("same agent again")))

        assert_equal 1, Task.where(agent: @agent, topic_id: @topic.id, status: "queued").count,
                     "the busy agent's new trigger must queue"
        assert_promoted stranded, "the free slot must go to the waiter that can use it"
      ensure
        Orchestration::ResourceTracker.for(@agent).reset!
      end

      # Promotion claims a slot; it must take the same lock admission takes, or
      # the two paths can hand out the same slot concurrently.
      test "claims the promoted slot inside one locked transaction" do
        locked_topic_ids = []
        lock_relation = Struct.new(:sink) do
          def find_by(id:)
            sink << id
            nil
          end
        end.new(locked_topic_ids)

        task_for(@agent, status: "queued")
        baseline_depth = Task.connection.open_transactions
        check_depth = nil
        counting_scope = Task.occupying_topic_slot(@topic.id, @creative.id)

        Topic.stub(:lock, lock_relation) do
          Task.stub(:occupying_topic_slot, ->(*) {
            check_depth ||= Task.connection.open_transactions
            counting_scope
          }) do
            AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
          end
        end

        # The promoted task runs inline here and drains the queue again as it
        # finishes, so the row is locked once per claim attempt — what matters
        # is that no claim skips the lock.
        assert_equal [ @topic.id ], locked_topic_ids.uniq,
                     "promotion must serialize on the same topic row admission uses"
        assert_predicate locked_topic_ids, :any?
        assert_operator check_depth, :>, baseline_depth,
                        "the occupancy check must run inside the claiming transaction"
      end

      # Promotion deleted every "⏳" notice in the topic unconditionally. With
      # topic_max > 1 it can leave other agents queued — coalesce_promoted!
      # absorbs same-agent siblings only — and the topic is allowed just one
      # deduplicated notice, so removing it strips the wait/stop signal from a
      # wait that is still real, until some later deferral happens to repost it.
      test "promotion keeps the waiting notice while another agent is still queued" do
        # Codex's shape: topic_max 2, one slot held by B, waiters for busy B and
        # for free A. Promoting A must not speak for B's wait, which continues.
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: nil,
          config: { "topic_max_concurrent_jobs" => 2 }
        )
        stuck_agent = other_agent("still-waiting")
        # Holds one of the two slots, which is also what makes its own waiter
        # ineligible: an agent may not take a second concurrent turn.
        task_for(stuck_agent, status: "running")
        task_for(@agent, status: "queued")
        task_for(stuck_agent, status: "queued")
        notice = @creative.comments.create!(
          content: "#{Comment::WAITING_NOTICE_PREFIX} Waiting (another task is running)",
          topic_id: @topic.id, private: false, skip_default_user: true,
          topic_concurrency_defer: true, skip_dispatch: true
        )

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert Comment.exists?(notice.id),
               "a waiter that is still queued still needs its notice"
      end

      # Control: once nothing is queued the notice must still go away, or the
      # topic keeps a "⏳" describing a wait that is over.
      test "promotion removes the waiting notice once the queue has drained" do
        task_for(@agent, status: "queued")
        notice = @creative.comments.create!(
          content: "#{Comment::WAITING_NOTICE_PREFIX} Waiting (another task is running)",
          topic_id: @topic.id, private: false, skip_default_user: true,
          topic_concurrency_defer: true, skip_dispatch: true
        )

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        refute Comment.exists?(notice.id),
               "nothing is waiting any more, so the notice must be cleaned up"
      end

      # Tasks carry topic_id with no foreign key, so a deleted topic leaves rows
      # pointing at a row that is gone. `lock!` returned that nil and skipped the
      # creative fallback entirely — admission, promotion and notice dedup then
      # run with no serialization at all, which is the failure the lock exists to
      # prevent rather than a missing niche.
      test "falls back to the creative row when the topic no longer exists" do
        missing_topic_id = Topic.maximum(:id).to_i + 1_000
        locked = []
        lock_relation = Struct.new(:sink) do
          def find_by(id:)
            sink << id
            nil
          end
        end.new(locked)

        Creative.stub(:lock, lock_relation) do
          TopicSlot.lock!(missing_topic_id, @creative.id)
        end

        assert_equal [ @creative.id ], locked,
                     "a stale topic id must still serialize on something stable"
      end

      # Control: a topic that does exist still locks the topic row, not the
      # creative — falling back always would serialize unrelated topics against
      # each other.
      test "locks the topic row when the topic exists" do
        locked_topics = []
        locked_creatives = []
        # The topic stub must *find* something: returning nil would be the
        # missing-topic case above, and the fallback firing would be correct.
        found = Struct.new(:sink, :row) do
          def find_by(id:)
            sink << id
            row
          end
        end
        absent = Struct.new(:sink) do
          def find_by(id:)
            sink << id
            nil
          end
        end

        Topic.stub(:lock, found.new(locked_topics, @topic)) do
          Creative.stub(:lock, absent.new(locked_creatives)) do
            assert_equal @topic, TopicSlot.lock!(@topic.id, @creative.id)
          end
        end

        assert_equal [ @topic.id ], locked_topics
        assert_empty locked_creatives, "an existing topic must not widen the lock to the creative"
      end

      # A promoted task holds the topic slot as `pending`, and deleting the
      # comment it answers cancels it right there — Comment#cancel_pending_tasks
      # takes no lock this path waits on. The coalescer re-reads the survivor
      # under its own lock and correctly declines to fold onto a cancelled row,
      # but it leaves the caller's object saying `pending`. Everything after it
      # reads that stale copy: the refresh writes a payload onto a cancelled
      # row, the status check passes, and the job is enqueued for a task that
      # returns on sight without draining. The waiters behind it are stranded
      # until orphan recovery.
      test "re-reads the promoted task after the fold before enqueueing it" do
        first = comment("@#{@agent.name}: first")
        survivor = task_for(@agent, status: "queued", comment: first)
        waiter = task_for(@agent, status: "queued", comment: comment("@#{@agent.name}: second"))

        # The documented window: after claim_next_waiter has promoted the
        # survivor, before the fold takes the task lock.
        fold = TaskCoalescer.method(:coalesce!)
        injected = false
        inject_delete = lambda do |task, scope: :older|
          unless injected
            injected = true
            first.destroy!
          end
          fold.call(task, scope: scope)
        end

        TaskCoalescer.stub(:coalesce!, inject_delete) do
          AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)
        end

        assert_equal "cancelled", survivor.reload.status,
                     "deleting the anchor cancels the promoted task — the premise of this test"
        assert_promoted waiter,
                        "the survivor lost its turn, so the queue behind it must be drained " \
                        "rather than left waiting on a task that will never run"
      end

      # Control: an ordinary promotion still enqueues the survivor. "Always
      # recurse after folding" would pass the test above while re-promoting
      # every turn and answering nothing.
      test "a promoted task that survives the fold is still the one enqueued" do
        survivor = task_for(@agent, status: "queued")

        AgentOrchestrator.dequeue_next_for_topic(@topic.id, @creative.id)

        assert_promoted survivor, "a healthy survivor must keep the slot it claimed"
      end

      # The same window does not close at the fold: the anchor can be deleted
      # after the recheck, or while the job sits in the queue. The job's own
      # first guard then returns without draining — the identical stranding,
      # reached by the identical user action a moment later.
      test "a cancelled task abandoned at job start still drains the topic" do
        cancelled = task_for(@agent, status: "pending")
        cancelled.update!(status: "cancelled")
        waiter = task_for(@agent, status: "queued")

        AiAgentJob.perform_now(cancelled)

        assert_promoted waiter,
                        "a task that leaves without running has to hand the topic slot on"
      end

      # Control: a cancelled task with no topic (a workflow subtask) has no
      # queue to drain, and must not fall into topic promotion at all.
      test "a cancelled task without a topic drains nothing" do
        orphan = Task.create!(
          name: "Subtask", status: "cancelled", trigger_event_name: "comment_created",
          agent: @agent, trigger_event_payload: { "creative" => { "id" => @creative.id } }
        )
        waiter = task_for(@agent, status: "queued")

        AiAgentJob.perform_now(orphan)

        assert_equal "queued", waiter.reload.status,
                     "a task that never held this topic's slot must not hand it out"
      end
    end
  end
end
