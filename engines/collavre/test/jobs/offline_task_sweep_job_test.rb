require "test_helper"

module Collavre
  class OfflineTaskSweepJobTest < ActiveJob::TestCase
    setup do
      @previous_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

    setup do
      @agent = User.create!(email: "offline-sweep@example.test", name: "Offline channel",
        password: SecureRandom.hex(24), llm_vendor: "anthropic", llm_model: "claude-code",
        created_by_id: users(:one).id)
      @topic = Topic.create!(creative: creatives(:tshirt), user: users(:one), name: "Private session",
        primary_agent_id: @agent.id, session_id: "recover-session")
      @task = Task.create!(name: "Interrupted channel turn", agent: @agent, topic_id: @topic.id,
        creative_id: @topic.creative_id, status: "delegated", updated_at: 5.minutes.ago)
    end

    test "crash without unsubscribe schedules agent and session recovery with a full grace period" do
      AgentSubscription.create!(agent: @agent, token: "dead", last_seen_at: 5.minutes.ago)
      freeze_time do
        scheduled_at = 30.seconds.from_now
        assert_enqueued_with(job: CancelOfflineDelegatedTasksJob, args: [ @agent.id, nil, nil ], at: scheduled_at) do
          OfflineTaskSweepJob.perform_now
        end
      end
      assert_equal "delegated", @task.reload.status
    end

    test "reconnect during sweep grace keeps existing delegated work" do
      OfflineTaskSweepJob.perform_now
      AgentSubscription.create!(agent: @agent, token: "back", session_id: "recover-session")
      travel 31.seconds
      perform_enqueued_jobs only: CancelOfflineDelegatedTasksJob
      assert_equal "delegated", @task.reload.status
    end

    test "live sibling cannot keep a dead private session task running" do
      AgentSubscription.create!(agent: @agent, token: "sibling", session_id: "other-session")
      OfflineTaskSweepJob.perform_now
      travel 31.seconds
      perform_enqueued_jobs only: CancelOfflineDelegatedTasksJob
      assert_equal "suspended", @task.reload.status
      assert_equal "agent_offline", @task.suspend_reason
    end

    test "channel dispatch interrupted while running is also recovered by the presence policy" do
      @task.update!(status: "running", updated_at: 5.minutes.ago)
      OfflineTaskSweepJob.perform_now
      travel 31.seconds
      perform_enqueued_jobs only: CancelOfflineDelegatedTasksJob
      assert_equal "suspended", @task.reload.status
      assert_equal "agent_offline", @task.suspend_reason
    end

    test "fresh turns and non-channel agents do not schedule offline cleanup" do
      @task.update!(updated_at: Time.current)
      assert_no_enqueued_jobs only: CancelOfflineDelegatedTasksJob do
        OfflineTaskSweepJob.perform_now
      end
      @task.update!(updated_at: 5.minutes.ago, agent: users(:ai_bot))
      assert_no_enqueued_jobs only: CancelOfflineDelegatedTasksJob do
        OfflineTaskSweepJob.perform_now
      end
    end
  end
end
