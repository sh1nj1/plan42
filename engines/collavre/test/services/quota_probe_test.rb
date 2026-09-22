require "test_helper"

class QuotaProbeTest < ActiveSupport::TestCase
  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @agent = users(:ai_bot)
    @probe = task("Probe")
    @sibling = task("Sibling")
    recover(@probe)
    recover(@sibling)
    @deadline = @agent.reload.quota_blocked_until
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "independent wakeups and sweeps release only one probe" do
    travel_to @deadline + 1 do
      assert_enqueued_jobs 1, only: Collavre::AiAgentJob do
        [ @sibling, @probe, @sibling, @probe ].each do |parked|
          Collavre::ResumeSuspendedTasksJob.perform_now(task_id: parked.id)
        end
        Collavre::ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      end
      assert_equal "pending", @probe.reload.status
      assert_equal "suspended", @sibling.reload.status
      assert_equal 0, @sibling.resume_count
      assert_equal :suspended, Collavre::Orchestration::Scheduler.new({}).schedule([ @agent.reload ]).first[:timing]
    end
  end

  test "different topic queues remain parked until their agent probe succeeds" do
    creative = Collavre::Creative.create!(description: "Probe topics", user: users(:one))
    Collavre::CreativeShare.create!(creative: creative, user: @agent, permission: "feedback")
    [ @probe, @sibling ].each do |parked|
      topic = creative.topics.create!(name: parked.name, user: users(:one))
      comment = creative.comments.create!(topic: topic, user: users(:one), content: "Continue", skip_dispatch: true)
      parked.update!(creative_id: creative.id, topic_id: topic.id, trigger_event_payload: {
        "creative" => { "id" => creative.id }, "topic" => { "id" => topic.id },
        "comment" => { "id" => comment.id, "content" => comment.content, "user_id" => users(:one).id }
      })
    end
    travel_to @deadline + 1 do
      assert_equal :unavailable, Collavre::Orchestration::TaskResumer.resume!(@sibling)
      assert_equal :resumed, Collavre::Orchestration::TaskResumer.resume!(@probe)
      assert_equal "pending", @probe.reload.status
      assert_equal "suspended", @sibling.reload.status
      start_probe
      Collavre::Quota::Recovery.succeeded!(@agent, task: @probe)
      Collavre::ResumeSuspendedTasksJob.perform_now(agent_id: @agent.id)
      assert_equal "pending", @sibling.reload.status
    end
  end

  test "provider guard claims the persisted election and parks an already enqueued sibling" do
    travel_to @deadline + 1 do
      start_probe
      @sibling.update!(status: "running")
      assert_raises(Collavre::TaskSuspendedError) { Collavre::Quota::Recovery.guard!(@sibling) }
      assert_equal "suspended", @sibling.reload.status
      assert_equal @probe.id, @agent.reload.quota_probe_task_id
      assert_equal generation(@probe), @agent.quota_probe_generation
    end
  end

  test "only successful elected execution resets retries and releases the backlog" do
    travel_to @deadline + 1 do
      start_probe
      Collavre::Quota::Recovery.succeeded!(@agent, task: @sibling)
      assert_equal 1, @agent.reload.quota_retry_count
      assert_enqueued_with(job: Collavre::ResumeSuspendedTasksJob, args: [ { agent_id: @agent.id } ]) do
        Collavre::Quota::Recovery.succeeded!(@agent, task: @probe)
      end
      assert_equal 0, @agent.reload.quota_retry_count
      assert_nil @agent.quota_probe_task_id
      assert_equal :resumed, Collavre::Orchestration::TaskResumer.resume!(@sibling)
      assert_no_enqueued_jobs(only: Collavre::ResumeSuspendedTasksJob) do
        Collavre::Quota::Recovery.succeeded!(@agent, task: @probe)
      end
    end
  end

  test "probe failure renews one backoff and never releases the sibling" do
    travel_to @deadline + 1 do
      start_probe
      recover(@probe)
      assert_equal 2, @agent.reload.quota_retry_count
      assert @agent.quota_blocked_until.future?
      assert_nil @agent.quota_probe_generation
      assert_equal @agent.quota_blocked_until, @sibling.reload.resume_not_before
      assert_equal :not_due, Collavre::Orchestration::TaskResumer.resume!(@sibling)
      # A delayed completion from the failed attempt is not proof of recovery,
      # even after the next reset deadline expires.
      travel_to @agent.quota_blocked_until + 1
      Collavre::Quota::Recovery.succeeded!(@agent, task: @probe)
      assert_equal 2, @agent.reload.quota_retry_count
    end
  end

  test "cancelled failed escalated and deleted probes elect the oldest remaining parked turn" do
    travel_to @deadline + 1 do
      %w[cancelled failed escalated].each do |status|
        @probe.update!(status: status)
        assert Collavre::Quota::Probe.available?(@agent.reload, @sibling)
      end
      @probe.destroy!
      start_probe(@sibling)
      assert_equal @sibling.id, @agent.reload.quota_probe_task_id
    end
  end

  test "a newly parked older turn does not displace a live elected probe" do
    travel_to @deadline + 1 do
      @agent.update!(quota_probe_task_id: @sibling.id)
      start_probe(@sibling)
      refute Collavre::Quota::Probe.available?(@agent.reload, @probe)
      assert Collavre::Quota::Probe.available?(@agent, @sibling)
    end
  end

  test "a retired probe generation cannot clear the current probe" do
    travel_to @deadline + 1 do
      start_probe
      old = Collavre::Task.find(@probe.id)
      @probe.update!(trigger_event_payload: Collavre::Orchestration::ExecutionFence.stamp({}))
      Collavre::Quota::Recovery.guard!(@probe)
      Collavre::Quota::Recovery.succeeded!(@agent, task: old)
      assert_equal 1, @agent.reload.quota_retry_count
      Collavre::Quota::Recovery.succeeded!(@agent, task: @probe)
      assert_equal 0, @agent.reload.quota_retry_count
    end
  end

  test "a stale worker cannot claim a newer probe generation" do
    travel_to @deadline + 1 do
      start_probe
      stale = Collavre::Task.find(@probe.id)
      @probe.update!(trigger_event_payload: Collavre::Orchestration::ExecutionFence.stamp({}))
      Collavre::Quota::Recovery.guard!(@probe)
      assert_raises(Collavre::CancelledError) { Collavre::Quota::Recovery.guard!(stale) }
      assert_equal generation(@probe), @agent.reload.quota_probe_generation
    end
  end

  test "a failed backlog enqueue preserves probe success for recurring sweep recovery" do
    travel_to @deadline + 1 do
      start_probe
      Collavre::ResumeSuspendedTasksJob.stub(:perform_later, ->(**) { raise ActiveJob::EnqueueError }) do
        Collavre::Quota::Recovery.succeeded!(@agent, task: @probe)
      end
      assert_equal 0, @agent.reload.quota_retry_count
      assert_equal :resumed, Collavre::Orchestration::TaskResumer.resume!(@sibling)
    end
  end

  private

  def task(name)
    Collavre::Task.create!(name: name, agent: @agent, status: "running",
                          trigger_event_payload: Collavre::Orchestration::ExecutionFence.stamp({}))
  end

  def recover(task)
    Collavre::Quota::Recovery.suspend!(task, Collavre::Quota::ExceededError.new)
  end

  def generation(task)
    Collavre::Orchestration::ExecutionFence.generation(task)
  end

  def start_probe(task = @probe)
    task.update!(status: "running", trigger_event_payload: Collavre::Orchestration::ExecutionFence.stamp({}))
    Collavre::Quota::Recovery.guard!(task)
  end
end
