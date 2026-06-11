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

      def create_policy_with_stuck_detection(enabled: true, task_threshold: 30, creative_threshold: 120,
                                             queued_orphan_threshold: 5)
        Collavre::OrchestratorPolicy.create!(
          policy_type: "stuck_detection",
          scope_type: nil,
          config: {
            "enabled" => enabled,
            "task_stuck_threshold_minutes" => task_threshold,
            "creative_stall_threshold_minutes" => creative_threshold,
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

      test "detects stalled creative" do
        policy = create_policy_with_stuck_detection(enabled: true, creative_threshold: 60)

        # Give AI agent access to creative
        Collavre::CreativeShare.create!(
          creative: @creative,
          user: @ai_agent,
          permission: :write
        )

        # Make creative stale
        @creative.update_columns(updated_at: 3.hours.ago)

        detector = StuckDetector.new
        stuck_items = detector.detect

        creative_stuck = stuck_items.find { |item| item.type == :creative }
        assert_not_nil creative_stuck
        assert_equal :stalled, creative_stuck.reason
        assert_equal @creative.id, creative_stuck.item.id
      ensure
        policy&.destroy
      end

      test "does not detect completed creative as stalled" do
        policy = create_policy_with_stuck_detection(enabled: true, creative_threshold: 60)

        # Complete the creative
        @creative.update!(progress: 1.0)
        @creative.update_columns(updated_at: 3.hours.ago)

        detector = StuckDetector.new
        stuck_items = detector.detect

        creative_stuck = stuck_items.find { |item| item.type == :creative && item.item.id == @creative.id }
        assert_nil creative_stuck
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

      def create_queued_task(comment_id:, creative_id: @creative.id, topic_id: @topic.id, age: 30.minutes)
        task = Collavre::Task.create!(
          name: "Queued waiter",
          agent: @ai_agent,
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

      test "self-heal drains a topic only once even with multiple orphaned waiters" do
        policy = create_policy_with_stuck_detection(enabled: true, queued_orphan_threshold: 5)
        create_queued_task(comment_id: 2006)
        create_queued_task(comment_id: 2007)

        calls = []
        Collavre::Orchestration::AgentOrchestrator.stub(
          :dequeue_next_for_topic, ->(t, c) { calls << [ t, c ] }
        ) do
          StuckDetector.new.detect_and_escalate
        end

        assert_equal 1, calls.count
        assert_equal [ @topic.id, @creative.id ], calls.first
      ensure
        policy&.destroy
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
