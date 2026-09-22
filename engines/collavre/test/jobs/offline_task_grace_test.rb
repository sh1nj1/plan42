require "test_helper"

module Collavre
  class OfflineTaskGraceTest < ActiveJob::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @agent = User.create!(name: "Grace channel", email: "grace-channel@example.test",
        password: SecureRandom.hex(24), llm_vendor: "anthropic", llm_model: "claude-code",
        created_by_id: users(:one).id)
      @task = Task.create!(name: "Delegated", agent: @agent, status: "delegated", updated_at: 1.hour.ago)
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_adapter }

    test "an online sweep does not pre-arm cleanup before the next disconnect" do
      AgentSubscription.create!(agent: @agent, token: "online")
      assert_no_enqueued_jobs only: CancelOfflineDelegatedTasksJob do
        OfflineTaskSweepJob.perform_now
      end
      assert_nil @task.reload.trigger_event_payload&.[](Orchestration::OfflineTaskGrace::KEY)
    end

    test "an old disconnect timer cannot shorten the next disconnect grace" do
      freeze_time do
        scope = Orchestration::OfflineTaskGrace.tasks_for(@agent)
        Orchestration::OfflineTaskGrace.disconnected!(scope)
        travel 10.seconds
        Orchestration::OfflineTaskGrace.connected!(@agent, nil)
        assert_nil @task.reload.trigger_event_payload[Orchestration::OfflineTaskGrace::KEY]
        travel 19.seconds
        Orchestration::OfflineTaskGrace.disconnected!(scope)
        deadline = 30.seconds.from_now
        travel 1.second
        assert_enqueued_with(job: CancelOfflineDelegatedTasksJob, at: deadline) do
          CancelOfflineDelegatedTasksJob.perform_now(@agent.id, "old-token")
        end
        assert_equal "delegated", @task.reload.status
        travel 30.seconds
        CancelOfflineDelegatedTasksJob.perform_now(@agent.id, nil)
        assert_equal "suspended", @task.reload.status
      end
    end

    test "legacy persisted jobs establish a durable grace rather than guessing disconnect time" do
      freeze_time do
        assert_enqueued_with(job: CancelOfflineDelegatedTasksJob, at: 30.seconds.from_now) do
          CancelOfflineDelegatedTasksJob.perform_now(@agent.id, nil)
        end
        assert_equal "delegated", @task.reload.status
        travel 31.seconds
        CancelOfflineDelegatedTasksJob.perform_now(@agent.id, nil)
        assert_equal "suspended", @task.reload.status
      end
    end

    test "reconnecting clears the previous attempt deadline before a suspended task resumes" do
      Orchestration::OfflineTaskGrace.write_deadline(@task, 1.minute.ago)
      @task.update!(status: "suspended", suspend_reason: "agent_offline", suspended_at: Time.current)
      Orchestration::OfflineTaskGrace.connected!(@agent, nil)
      assert_nil @task.reload.trigger_event_payload[Orchestration::OfflineTaskGrace::KEY]
    end

    test "sibling reconnect does not reset a different private session deadline" do
      topic = Topic.create!(creative: creatives(:tshirt), user: users(:one), name: "Other session",
        primary_agent_id: @agent.id, session_id: "original-session")
      @task.update!(topic_id: topic.id)
      Orchestration::OfflineTaskGrace.disconnected!(Orchestration::OfflineTaskGrace.tasks_for(@agent))
      original = @task.reload.trigger_event_payload[Orchestration::OfflineTaskGrace::KEY]
      Orchestration::OfflineTaskGrace.connected!(@agent, "sibling-session")
      assert_equal original, @task.reload.trigger_event_payload[Orchestration::OfflineTaskGrace::KEY]
      Orchestration::OfflineTaskGrace.connected!(@agent, "original-session")
      assert_nil @task.reload.trigger_event_payload[Orchestration::OfflineTaskGrace::KEY]
    end
  end
end
