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

    test "expired tasks suspend while unexpired tasks keep their own deadlines" do
      freeze_time do
        Orchestration::OfflineTaskGrace.write_deadline(@task, Time.current)
        waiting = Task.create!(name: "Waiting", agent: @agent, status: "running")
        newest = Task.create!(name: "Newest", agent: @agent, status: "pending")
        Orchestration::OfflineTaskGrace.write_deadline(waiting, 10.seconds.from_now)

        assert_enqueued_with(job: CancelOfflineDelegatedTasksJob,
          args: [ @agent.id, nil, nil ], at: 10.seconds.from_now) do
          CancelOfflineDelegatedTasksJob.perform_now(@agent.id, nil)
        end
        assert_equal "suspended", @task.reload.status
        assert_equal "running", waiting.reload.status
        assert_equal "pending", newest.reload.status

        travel 30.seconds
        assert_no_enqueued_jobs only: CancelOfflineDelegatedTasksJob do
          CancelOfflineDelegatedTasksJob.perform_now(@agent.id, nil)
        end
        assert_equal "suspended", waiting.reload.status
        assert_equal "suspended", newest.reload.status
      end
    end

    test "continuing private session traffic does not postpone older turns" do
      freeze_time do
        topic = Topic.create!(creative: creatives(:tshirt), user: users(:one), name: "Offline session",
          primary_agent_id: @agent.id, session_id: "offline-session")
        AgentSubscription.create!(agent: @agent, token: "sibling", session_id: "sibling-session")
        @task.update!(topic_id: topic.id)
        Orchestration::OfflineTaskGrace.write_deadline(@task, Time.current)
        older = @task

        3.times do |index|
          newest = Task.create!(name: "Incoming #{index}", agent: @agent, topic_id: topic.id, status: "queued")
          assert_enqueued_with(job: CancelOfflineDelegatedTasksJob,
            args: [ @agent.id, "token", "offline-session" ], at: 30.seconds.from_now) do
            CancelOfflineDelegatedTasksJob.perform_now(@agent.id, "token", "offline-session")
          end
          assert_equal "suspended", older.reload.status
          assert_equal "queued", newest.reload.status
          older = newest
          travel 30.seconds
        end
      end
    end

    test "reconnecting clears the previous attempt deadline before a suspended task resumes" do
      Orchestration::OfflineTaskGrace.write_deadline(@task, 1.minute.ago)
      @task.update!(status: "suspended", suspend_reason: "agent_offline", suspended_at: Time.current)
      Orchestration::OfflineTaskGrace.connected!(@agent, nil)
      assert_nil @task.reload.trigger_event_payload[Orchestration::OfflineTaskGrace::KEY]
    end

    test "final sibling disconnect preserves an already offline private turn deadline" do
      freeze_time do
        topic = Topic.create!(creative: creatives(:tshirt), user: users(:one), name: "First session",
          primary_agent_id: @agent.id, session_id: "first-session")
        @task.update!(topic_id: topic.id)
        shared = Task.create!(name: "Shared turn", agent: @agent, status: "delegated")
        grace = Orchestration::OfflineTaskGrace
        grace.disconnected!(grace.tasks_for(@agent, "first-session"))
        original = grace.deadline(@task)

        travel 10.seconds
        grace.disconnected!(grace.tasks_for(@agent))
        assert_equal original, grace.deadline(@task.reload)
        assert_equal 30.seconds.from_now, grace.deadline(shared.reload)

        travel 20.seconds
        CancelOfflineDelegatedTasksJob.perform_now(@agent.id, nil)
        assert_equal "suspended", @task.reload.status
        assert_equal "delegated", shared.reload.status
      end
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
