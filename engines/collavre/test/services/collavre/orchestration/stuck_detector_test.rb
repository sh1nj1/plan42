require "test_helper"

module Collavre
  module Orchestration
    class StuckDetectorTest < ActiveSupport::TestCase
      setup do
        @human_user = Collavre::User.create!(
          name: "Admin",
          email: "admin-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )

        @ai_agent = Collavre::User.create!(
          name: "dev-agent",
          email: "dev-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are a developer agent."
        )

        @creative = Collavre::Creative.create!(
          description: "Test project",
          user: @human_user,
          progress: 0.5
        )

        # Give human admin access
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @human_user,
          permission: :admin
        )

        # Create topic for tasks
        @topic = Collavre::Topic.create!(
          creative: @creative,
          name: "Test topic",
          user: @human_user
        )
      end

      def create_policy_with_stuck_detection(enabled: true, task_threshold: 30, queued_orphan_threshold: 5)
        Collavre::OrchestratorPolicy.create!(
          policy_type: "stuck_detection",
          scope_type: nil,
          config: {
            "enabled" => enabled,
            "task_stuck_threshold_minutes" => task_threshold,
            "queued_orphan_threshold_minutes" => queued_orphan_threshold,
            "create_system_comment" => true
          }
        )
      end

      # Basic functionality tests
      test "returns empty result when disabled" do
        policy = create_policy_with_stuck_detection(enabled: false)

        # Create a stuck task
        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id,
          created_at: 1.hour.ago,
          updated_at: 1.hour.ago
        )

        detector = StuckDetector.new
        result = detector.detect_and_escalate

        assert_empty result.stuck_items
        assert_equal 0, result.escalated_count
      ensure
        policy&.destroy
      end

      test "detects stuck running task" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        # Create a task that's been running for too long
        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new
        stuck_items = detector.detect

        assert_equal 1, stuck_items.count
        assert_equal :task, stuck_items.first.type
        assert_equal :no_progress, stuck_items.first.reason
        assert_equal task.id, stuck_items.first.item.id
      ensure
        policy&.destroy
      end

      test "does not detect recently updated task as stuck" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        # Create a task that was updated recently
        task = Collavre::Task.create!(
          name: "Active task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        # Task was updated just now, so it's not stuck

        detector = StuckDetector.new
        stuck_items = detector.detect

        task_stuck = stuck_items.find { |item| item.type == :task && item.item.id == task.id }
        assert_nil task_stuck
      ensure
        policy&.destroy
      end

      test "does not alert for inactive creatives" do
        policy = create_policy_with_stuck_detection(enabled: true)
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @ai_agent,
          permission: :write
        )
        @creative.update_columns(updated_at: 3.hours.ago)

        inbox = Collavre::Creative.inbox_for(@human_user)

        assert_no_difference -> { inbox.comments.count } do
          result = StuckDetector.new.detect_and_escalate

          assert_empty result.stuck_items
          assert_equal 0, result.escalated_count
        end
      ensure
        policy&.destroy
      end

      test "escalates stuck task on a creative that has a public admin share" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        # A public share may hold admin permission and still carry no user
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: nil,
          permission: :admin
        )

        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new
        result = detector.detect_and_escalate

        assert_equal 1, result.escalated_count
        task_stuck = result.stuck_items.find { |item| item.type == :task }
        assert_equal [ @human_user.id ], task_stuck.escalation_targets.map(&:id)
      ensure
        policy&.destroy
      end

      test "escalates and creates inbox item" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        inbox = Collavre::Creative.inbox_for(@human_user)
        initial_inbox_count = inbox.comments.count

        detector = StuckDetector.new
        result = detector.detect_and_escalate

        assert_equal 1, result.escalated_count
        assert_equal initial_inbox_count + 1, inbox.comments.reload.count

        inbox_comment = inbox.comments.order(:id).last
        assert_includes inbox_comment.content, "Stuck task"
      ensure
        policy&.destroy
      end

      test "does not re-escalate recently escalated task" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new

        # First escalation
        result1 = detector.detect_and_escalate
        assert_equal 1, result1.escalated_count

        # Second escalation should be blocked by cache
        result2 = detector.detect_and_escalate
        assert_equal 0, result2.escalated_count
      ensure
        policy&.destroy
        Rails.cache.clear
      end

      test "finds escalation targets from creative admin permission" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        # Create another admin
        admin2 = Collavre::User.create!(
          name: "Admin2",
          email: "admin2-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: admin2,
          permission: :admin
        )

        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new
        stuck_items = detector.detect

        escalation_targets = stuck_items.first.escalation_targets
        assert_includes escalation_targets.map(&:id), @human_user.id
        assert_includes escalation_targets.map(&:id), admin2.id
      ensure
        policy&.destroy
      end

      test "auto-recovers stuck tasks by marking them as failed" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new
        detector.detect_and_escalate

        assert_equal "failed", task.reload.status
      ensure
        policy&.destroy
      end

      test "auto-recovery dequeues next task for the topic" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        stuck_task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "comment" => { "id" => 999, "content" => "test" },
            "topic" => { "id" => @topic.id }
          },
          topic_id: @topic.id
        )
        stuck_task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        queued_task = Collavre::Task.create!(
          name: "Queued task",
          agent: @ai_agent,
          status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "comment" => { "id" => 1000, "content" => "queued" },
            "topic" => { "id" => @topic.id }
          },
          topic_id: @topic.id
        )

        detector = StuckDetector.new
        detector.detect_and_escalate

        assert_equal "failed", stuck_task.reload.status
        # Queued task should have been dequeued (no longer "queued")
        assert_not_equal "queued", queued_task.reload.status
      ensure
        policy&.destroy
      end

      test "excludes AI agents from escalation targets" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        # Give AI agent admin permission (should be excluded)
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @ai_agent,
          permission: :admin
        )

        task = Collavre::Task.create!(
          name: "Stuck task",
          agent: @ai_agent,
          status: "running",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new
        stuck_items = detector.detect

        escalation_targets = stuck_items.first.escalation_targets
        assert_not_includes escalation_targets.map(&:id), @ai_agent.id
      ensure
        policy&.destroy
      end

      test "detects and auto-recovers stuck delegated Claude Channel task" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        task = Collavre::Task.create!(
          name: "Stuck delegated task",
          agent: @ai_agent,
          status: "delegated",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id,
          creative_id: @creative.id
        )
        task.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        detector = StuckDetector.new
        stuck_items = detector.detect

        assert_equal 1, stuck_items.count
        assert_equal task.id, stuck_items.first.item.id

        Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(_t, _c) { nil }) do
          detector.detect_and_escalate
        end

        assert_equal "failed", task.reload.status
      ensure
        policy&.destroy
      end

      # --- Orphaned queued waiter detection & self-heal ---

      def create_queued_task(comment_id:, creative_id: @creative.id, topic_id: @topic.id,
                            age: 30.minutes, agent: @ai_agent)
        task = Collavre::Task.create!(
          name: "Queued waiter",
          agent: agent,
          status: "queued",
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => creative_id },
            "comment" => { "id" => comment_id, "content" => "queued" },
            "topic" => { "id" => topic_id }
          },
          topic_id: topic_id,
          creative_id: creative_id
        )
        task.update_columns(created_at: age.ago, updated_at: age.ago)
        task
      end

      test "detects orphaned queued waiter with no live blocker" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        orphan = create_queued_task(comment_id: 2001)

        stuck_items = StuckDetector.new.detect
        orphan_item = stuck_items.find { |i| i.type == :queued_orphan }

        assert_not_nil orphan_item
        assert_equal :orphaned_waiter, orphan_item.reason
        assert_equal orphan.id, orphan_item.item.id
      ensure
        policy&.destroy
      end

      test "does not flag queued waiter while a live blocker exists for the topic" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        create_queued_task(comment_id: 2002)

        # Live blocker running in the same topic/creative
        Collavre::Task.create!(
          name: "Live blocker",
          agent: @ai_agent,
          status: "running",
          topic_id: @topic.id,
          creative_id: @creative.id
        )

        stuck_items = StuckDetector.new.detect
        assert_nil stuck_items.find { |i| i.type == :queued_orphan }
      ensure
        policy&.destroy
      end

      test "does not flag recently queued waiter within threshold" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        create_queued_task(comment_id: 2003, age: 1.minute)

        stuck_items = StuckDetector.new.detect
        assert_nil stuck_items.find { |i| i.type == :queued_orphan }
      ensure
        policy&.destroy
      end

      test "self-heals orphaned queued waiter by draining the topic queue" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        orphan = create_queued_task(comment_id: 2004)

        calls = []
        Collavre::Orchestration::AgentOrchestrator.stub(
          :dequeue_next_for_topic, ->(t, c) { calls << [ t, c ] }
        ) do
          StuckDetector.new.detect_and_escalate
        end

        assert_equal [ [ @topic.id, @creative.id ] ], calls
      ensure
        policy&.destroy
      end

      test "does not escalate orphaned queued waiters to admins" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        create_queued_task(comment_id: 2005)

        inbox = Collavre::Creative.inbox_for(@human_user)
        initial_inbox_count = inbox.comments.count

        result = nil
        Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(_t, _c) { nil }) do
          result = StuckDetector.new.detect_and_escalate
        end

        assert_equal 0, result.escalated_count
        assert_equal initial_inbox_count, inbox.comments.reload.count
      ensure
        policy&.destroy
      end

      test "self-heal fills only the free slots when several waiters are orphaned" do
        # No scheduling policy → the topic serializes (one slot). Each dequeue
        # moves a waiter queued -> pending synchronously (occupying_topic_slot
        # counts pending), so the capacity recheck stops after the single free
        # slot is filled — only one promotion even with two orphaned waiters.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        create_queued_task(comment_id: 2006)
        create_queued_task(comment_id: 2007)

        calls = []
        Collavre::Orchestration::AgentOrchestrator.stub(
          :dequeue_next_for_topic, lambda { |t, c|
            calls << [ t, c ]
            Collavre::Task.queued_for_topic(t, c).first&.update!(status: "pending")
          }
        ) do
          StuckDetector.new.detect_and_escalate
        end

        assert_equal 1, calls.count
        assert_equal [ @topic.id, @creative.id ], calls.first
      ensure
        policy&.destroy
      end

      test "self-heal fills every free slot under topic_max > 1" do
        # topic_max=2 with no live blocker = two free slots, so two orphaned
        # waiters must both be promoted in one detection cycle. The capacity
        # recheck counts each just-promoted pending task, bounding promotions to
        # the free-slot count; a per-topic dedupe would instead leave the second
        # waiter orphaned until the next StuckDetector run.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 2)
        create_queued_task(comment_id: 2020)
        create_queued_task(comment_id: 2021)

        calls = []
        Collavre::Orchestration::AgentOrchestrator.stub(
          :dequeue_next_for_topic, lambda { |t, c|
            calls << [ t, c ]
            Collavre::Task.queued_for_topic(t, c).first&.update!(status: "pending")
          }
        ) do
          StuckDetector.new.detect_and_escalate
        end

        assert_equal 2, calls.count
      ensure
        sched&.destroy
        policy&.destroy
      end

      test "self-heal promotes every orphaned waiter without cancelling the rest" do
        # Real dequeue path (the topic_max>1 test above stubs it). Promoting one
        # waiter destroys the topic's ⏳ notices, and a notice's destroy callback
        # cancels a queued waiter — so without suppression the second orphan is
        # cancelled instead of promoted, dropping its work.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 2)

        # A human comment so refresh_deferred_context! keeps the promoted waiters
        # (it cancels a promoted task that has no eligible triggering comment).
        @creative.comments.create!(
          content: "please respond", topic_id: @topic.id,
          user: @human_user, skip_dispatch: true
        )

        # Two DIFFERENT agents: two waiters for the same agent in the same topic
        # are one conversation turn and Orchestration::TaskCoalescer folds them
        # together on promotion. Distinct agents are what topic_max=2 actually
        # buys, and they are what must both survive the notice cleanup.
        w1 = create_queued_task(comment_id: 2030)
        w2 = create_queued_task(comment_id: 2031, agent: second_agent)
        2.times do
          @creative.comments.create!(
            content: "⏳ waiting on the topic", topic_id: @topic.id,
            private: false, skip_default_user: true, topic_concurrency_defer: true
          )
        end

        Collavre::AiAgentJob.stub(:perform_later, ->(*) { nil }) do
          StuckDetector.new.detect_and_escalate
        end

        assert_equal "pending", w1.reload.status, "first orphan must be promoted"
        assert_equal "pending", w2.reload.status,
                     "second orphan must be promoted, not cancelled by notice cleanup"
      ensure
        sched&.destroy
        policy&.destroy
      end

      test "self-heal folds same-agent orphans into the promoted turn" do
        # Same agent + same topic = one conversation turn. Promoting both would
        # answer the same latest comment twice (refresh_deferred_context! points
        # every waiter at it), so the straggler is absorbed instead.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 2)

        @creative.comments.create!(
          content: "please respond", topic_id: @topic.id,
          user: @human_user, skip_dispatch: true
        )

        w1 = create_queued_task(comment_id: 2040)
        w2 = create_queued_task(comment_id: 2041)

        Collavre::AiAgentJob.stub(:perform_later, ->(*) { nil }) do
          StuckDetector.new.detect_and_escalate
        end

        assert_equal "pending", w1.reload.status
        assert_equal "cancelled", w2.reload.status,
                     "a same-agent straggler must be absorbed, not answered separately"
        assert_includes w1.trigger_event_payload[TaskCoalescer::PAYLOAD_KEY], 2041,
                        "the absorbed waiter's comment must still reach the agent"
      ensure
        sched&.destroy
        policy&.destroy
      end

      # A second, independent agent — the shape topic_max > 1 actually serves.
      def second_agent
        @second_agent ||= Collavre::User.create!(
          name: "dev-agent-2",
          email: "dev2-#{SecureRandom.hex(4)}@agent.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4",
          system_prompt: "You are a second developer agent."
        )
      end

      def create_scheduling_policy(topic_max:)
        Collavre::OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: nil,
          config: { "topic_max_concurrent_jobs" => topic_max }
        )
      end

      def create_running_blocker(name:)
        Collavre::Task.create!(
          name: name,
          agent: @ai_agent,
          status: "running",
          topic_id: @topic.id,
          creative_id: @creative.id
        )
      end

      test "flags orphaned waiter when topic has a free slot under topic_max > 1" do
        # topic_max=2 with a single live blocker leaves one free slot, so a
        # missed dequeue orphans the waiter — it must be self-healed rather than
        # suppressed until the last blocker terminates.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 2)
        orphan = create_queued_task(comment_id: 2010)
        create_running_blocker(name: "Live blocker 1")

        stuck_items = StuckDetector.new.detect
        orphan_item = stuck_items.find { |i| i.type == :queued_orphan }

        assert_not_nil orphan_item
        assert_equal orphan.id, orphan_item.item.id
      ensure
        sched&.destroy
        policy&.destroy
      end

      test "does not flag waiter when topic is at capacity under topic_max > 1" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 2)
        create_queued_task(comment_id: 2011)
        create_running_blocker(name: "Live blocker 1")
        create_running_blocker(name: "Live blocker 2")

        stuck_items = StuckDetector.new.detect
        assert_nil stuck_items.find { |i| i.type == :queued_orphan }
      ensure
        sched&.destroy
        policy&.destroy
      end

      def create_topic_scheduling_policy(topic_max:)
        Collavre::OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "Topic",
          scope_id: @topic.id,
          config: { "topic_max_concurrent_jobs" => topic_max }
        )
      end

      test "honors topic-scoped topic_max below the global limit" do
        # Global allows 2 concurrent, but this topic is serialized to 1. A single
        # live blocker therefore fills the topic — the waiter is legitimately
        # queued and must NOT be flagged. Resolving against the empty-context
        # detector resolver would see the global 2 and wrongly self-heal,
        # violating the topic's serialization.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        global = create_scheduling_policy(topic_max: 2)
        scoped = create_topic_scheduling_policy(topic_max: 1)
        create_queued_task(comment_id: 2012)
        create_running_blocker(name: "Live blocker 1")

        stuck_items = StuckDetector.new.detect
        assert_nil stuck_items.find { |i| i.type == :queued_orphan }
      ensure
        scoped&.destroy
        global&.destroy
        policy&.destroy
      end

      test "honors topic-scoped topic_max above the global limit" do
        # Global serializes to 1, but this topic allows 2. A single live blocker
        # leaves a free slot, so a missed dequeue orphans the waiter — it must be
        # self-healed, not suppressed by the global limit.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        global = create_scheduling_policy(topic_max: 1)
        scoped = create_topic_scheduling_policy(topic_max: 2)
        orphan = create_queued_task(comment_id: 2013)
        create_running_blocker(name: "Live blocker 1")

        stuck_items = StuckDetector.new.detect
        orphan_item = stuck_items.find { |i| i.type == :queued_orphan }

        assert_not_nil orphan_item
        assert_equal orphan.id, orphan_item.item.id
      ensure
        scoped&.destroy
        global&.destroy
        policy&.destroy
      end

      def create_pending_claim(name:)
        Collavre::Task.create!(
          name: name,
          agent: @ai_agent,
          status: "pending",
          topic_id: @topic.id,
          creative_id: @creative.id
        )
      end

      test "does not flag waiter when a prior dequeue is still pending" do
        # topic_max=1 and a waiter was already dequeued (queued -> pending) but its
        # AiAgentJob has not started, so running_for_topic is empty. The remaining
        # queued waiter must NOT be flagged: the pending task is a claimed slot, and
        # promoting the waiter would double-dequeue into a topic_max=1 topic.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 1)
        create_pending_claim(name: "Claimed but not started")
        create_queued_task(comment_id: 2014)

        stuck_items = StuckDetector.new.detect
        assert_nil stuck_items.find { |i| i.type == :queued_orphan }
      ensure
        sched&.destroy
        policy&.destroy
      end

      def create_pending_approval(name:)
        Collavre::Task.create!(
          name: name,
          agent: @ai_agent,
          status: "pending_approval",
          topic_id: @topic.id,
          creative_id: @creative.id
        )
      end

      test "does not flag waiter when a task is paused awaiting tool approval" do
        # topic_max=1 and the slot holder is paused on pending_approval: it keeps
        # its resource (should_release = false) and does NOT drain the queue
        # (dequeue only fires on terminal statuses). running_for_topic is empty,
        # but the queued waiter is still legitimately blocked — promoting it would
        # run a second task concurrently with the approval-paused one, violating
        # topic serialization. The waiter must NOT be flagged.
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        sched = create_scheduling_policy(topic_max: 1)
        create_pending_approval(name: "Paused awaiting approval")
        create_queued_task(comment_id: 2015)

        stuck_items = StuckDetector.new.detect
        assert_nil stuck_items.find { |i| i.type == :queued_orphan }
      ensure
        sched&.destroy
        policy&.destroy
      end

      test "fails parent workflow when auto-recovering delegated subtask" do
        policy = create_policy_with_stuck_detection(enabled: true, task_threshold: 30)

        parent = Collavre::Task.create!(
          name: "Parent workflow",
          agent: @ai_agent,
          status: "running",
          topic_id: @topic.id,
          creative_id: @creative.id
        )

        sub = Collavre::Task.create!(
          name: "Delegated subtask",
          agent: @ai_agent,
          status: "delegated",
          trigger_event_payload: { "creative" => { "id" => @creative.id } },
          topic_id: @topic.id,
          creative_id: @creative.id,
          parent_task_id: parent.id
        )
        sub.update_columns(created_at: 1.hour.ago, updated_at: 1.hour.ago)

        executor = Minitest::Mock.new
        executor.expect(:fail_subtask!, nil) do |passed_sub, error_message:|
          passed_sub.id == sub.id && error_message.is_a?(String)
        end

        Collavre::Comments::WorkflowExecutor.stub(:new, ->(_pt) { executor }) do
          Collavre::Orchestration::AgentOrchestrator.stub(:dequeue_next_for_topic, ->(_t, _c) { nil }) do
            StuckDetector.new.detect_and_escalate
          end
        end

        assert_equal "failed", sub.reload.status
        executor.verify
      ensure
        policy&.destroy
      end
    end
  end
end
