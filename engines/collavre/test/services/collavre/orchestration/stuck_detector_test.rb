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

      def create_policy_with_stuck_detection(enabled: true, task_threshold: 30, creative_threshold: 120)
        Collavre::OrchestratorPolicy.create!(
          policy_type: "stuck_detection",
          scope_type: nil,
          config: {
            "enabled" => enabled,
            "task_stuck_threshold_minutes" => task_threshold,
            "creative_stall_threshold_minutes" => creative_threshold,
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
    end
  end
end
