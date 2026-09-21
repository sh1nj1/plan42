# frozen_string_literal: true

require "test_helper"
require Rails.root.join(
  "engines/collavre/db/migrate/20260812000000_remove_workflow_columns_from_tasks"
)

# The migration cancels workflow tasks that were still mid-flight when /work was
# removed. Cancelling the row is not enough: those statuses were paused with no
# live worker to run AiAgentJob's ensure-block, so the agent's ResourceTracker
# slot and the topic queue are this migration's to hand back.
#
# The column drop itself is exercised by the schema; these tests cover the data
# cleanup, which is driven off rows read before the columns disappear.
class RemoveWorkflowColumnsFromTasksTest < ActiveSupport::TestCase
  setup do
    @migration = RemoveWorkflowColumnsFromTasks.new
    @agent = users(:ai_bot)
    @creative = creatives(:tshirt)
    @tracker = Collavre::Orchestration::ResourceTracker.for(@agent)
    @tracker.reset!
  end

  teardown do
    @tracker.reset!
  end

  def row(id:, status:, agent_id: @agent.id, topic_id: nil, creative_id: nil)
    { "id" => id, "agent_id" => agent_id, "status" => status,
      "topic_id" => topic_id, "creative_id" => creative_id }
  end

  test "releases the agent slot a paused workflow task still holds" do
    @tracker.reserve!(42)
    assert_equal 1, @tracker.active_jobs

    @migration.send(:release_slots, [ row(id: 42, status: "pending_approval") ])

    assert_equal 0, @tracker.active_jobs
  end

  test "releases every status that reached reserve!" do
    %w[running delegated pending_approval].each_with_index do |status, index|
      id = 100 + index
      @tracker.reserve!(id)
      @migration.send(:release_slots, [ row(id: id, status: status) ])

      assert_equal 0, @tracker.active_jobs, "#{status} should hand the slot back"
    end
  end

  test "leaves other agents' reservations alone" do
    other = Collavre::User.create!(
      name: "other-agent", email: "other-#{SecureRandom.hex(4)}@agent.test",
      password: "password123", llm_vendor: "openai", llm_model: "gpt-4"
    )
    other_tracker = Collavre::Orchestration::ResourceTracker.for(other)
    other_tracker.reserve!(7)
    @tracker.reserve!(8)

    @migration.send(:release_slots, [ row(id: 8, status: "running") ])

    assert_equal 0, @tracker.active_jobs
    assert_equal 1, other_tracker.active_jobs
  ensure
    other_tracker&.reset!
  end

  test "skips rows with no agent" do
    assert_nothing_raised do
      @migration.send(:release_slots, [ row(id: 9, status: "running", agent_id: nil) ])
    end
  end

  test "skips a row whose agent no longer exists" do
    assert_nothing_raised do
      @migration.send(:release_slots, [ row(id: 9, status: "running", agent_id: 0) ])
    end
  end

  test "drains each distinct topic once so queued waiters are not stranded" do
    topic = Collavre::Topic.create!(name: "Drain topic", creative: @creative, user: users(:one))
    drained = []
    Collavre::Orchestration::AgentOrchestrator.stub(
      :dequeue_next_for_topic, ->(topic_id, creative_id) { drained << [ topic_id, creative_id ] }
    ) do
      @migration.send(:release_slots, [
        row(id: 1, status: "running", topic_id: topic.id, creative_id: @creative.id),
        row(id: 2, status: "pending", topic_id: topic.id, creative_id: @creative.id),
        row(id: 3, status: "running", topic_id: nil, creative_id: @creative.id)
      ])
    end

    assert_equal [ [ topic.id, @creative.id ] ], drained
  end

  test "a cleanup failure never fails the schema change" do
    @tracker.reserve!(5)
    Collavre::Orchestration::ResourceTracker.stub(:for, ->(_agent) { raise "cache down" }) do
      assert_nothing_raised do
        @migration.send(:release_slots, [ row(id: 5, status: "running") ])
      end
    end
  end
end
