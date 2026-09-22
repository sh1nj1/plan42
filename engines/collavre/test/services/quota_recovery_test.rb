require "test_helper"

class QuotaRecoveryTest < ActiveSupport::TestCase
  setup do
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @agent = users(:ai_bot)
    @task = Collavre::Task.create!(name: "Quota recovery", agent: @agent, status: "running",
                                 trigger_event_name: "test", trigger_event_payload: {})
  end

  teardown do
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  test "reset plus positive jitter is persisted and duplicate failures do not reschedule" do
    freeze_time do
      reset = 2.days.from_now
      assert_equal :suspended, recover(reset)
      assert_equal "suspended", @task.reload.status
      assert @task.resume_not_before.between?(reset + 5, reset + 30)
      assert_equal @task.resume_not_before, @agent.reload.quota_blocked_until
      assert_equal 1, @agent.quota_retry_count
      deadline = @task.resume_not_before
      assert_no_enqueued_jobs(only: Collavre::ResumeSuspendedTasksJob) { assert_nil recover(reset) }
      assert_equal deadline, @task.reload.resume_not_before
      assert_equal 1, @agent.reload.quota_retry_count
    end
  end

  test "missing reset uses increasing bounded probes then blocks further attempts" do
    freeze_time do
      3.times do |attempt|
        @task.update!(status: "running")
        recover
        assert @task.reload.resume_not_before.between?(Time.current + 30.minutes * 2**attempt + 5,
                                                       Time.current + 30.minutes * 2**attempt + 30)
        travel_to @task.resume_not_before + 1
      end
      @task.update!(status: "running")
      recover
      assert @agent.reload.quota_retry_exhausted?
      assert_nil @task.reload.resume_not_before
      assert_equal :unavailable, Collavre::Orchestration::TaskResumer.resume!(@task)
    end
  end

  test "sibling failures share an agent block without spending another probe" do
    recover(1.hour.from_now)
    deadline = @task.reload.resume_not_before
    sibling = Collavre::Task.create!(name: "Sibling quota", agent: @agent, status: "running", trigger_event_payload: {})
    Collavre::Quota::Recovery.suspend!(sibling, Collavre::Quota::ExceededError.new)
    assert_equal 1, @agent.reload.quota_retry_count
    assert_equal deadline, sibling.reload.resume_not_before
    assert_equal "suspended", sibling.status
  end

  test "cancelled and completed tasks do not block agent or reserve another wakeup" do
    %w[cancelled done].each do |status|
      @task.update!(status: status)
      assert_no_enqueued_jobs(only: Collavre::ResumeSuspendedTasksJob) { assert_nil recover }
      assert_equal 0, @agent.reload.quota_retry_count
    end
  end

  test "fresh database instances still respect scheduled time and resume only once" do
    recover(2.hours.from_now)
    assert_equal :not_due, Collavre::Orchestration::TaskResumer.resume!(Collavre::Task.find(@task.id))
    travel_to @task.reload.resume_not_before + 1 do
      Collavre::ResumeSuspendedTasksJob.perform_now(task_id: @task.id)
      assert_equal 1, @task.reload.resume_count
      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
        Collavre::ResumeSuspendedTasksJob.perform_now(task_id: @task.id)
      end
    end
  end

  test "execution guard suspends new work before any provider call" do
    @agent.update!(quota_blocked_until: 1.hour.from_now)
    assert_raises(Collavre::TaskSuspendedError) { Collavre::AiAgentService.new(@task).call }
    assert_equal "suspended", @task.reload.status
  end

  test "success clears old backoff but preserves sibling newer failure" do
    @agent.update!(quota_retry_count: 2, quota_blocked_until: 1.minute.ago)
    Collavre::Quota::Recovery.succeeded!(@agent)
    assert_equal 0, @agent.reload.quota_retry_count
    @agent.update!(quota_retry_count: 2, quota_blocked_until: 1.hour.from_now)
    Collavre::Quota::Recovery.succeeded!(@agent)
    assert_equal 2, @agent.reload.quota_retry_count
  end

  test "scheduler parks new requests while blocked and rejects exhausted probes" do
    @agent.update!(quota_blocked_until: 1.hour.from_now)
    decision = Collavre::Orchestration::Scheduler.new({}).schedule([ @agent ]).first
    assert_equal :suspended, decision[:timing]
    assert_equal @agent.quota_blocked_until, decision[:resume_not_before]
    @agent.update!(quota_retry_exhausted: true)
    assert_equal :rejected, Collavre::Orchestration::Scheduler.new({}).schedule([ @agent ]).first[:timing]
  end

  test "blocked new requests become durable suspended rows without provider jobs" do
    deadline = 1.hour.from_now.change(usec: 0)
    @agent.update!(quota_blocked_until: deadline)
    context = { "creative" => { "id" => creatives(:tshirt).id }, "comment" => { "id" => 987654 } }
    orchestrator = Collavre::Orchestration::AgentOrchestrator.new(event_name: "comment_created", context: context)
    decision = { agent: @agent, timing: :suspended, resume_not_before: deadline }
    assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
      assert_equal @agent, orchestrator.send(:enqueue_scheduled, @agent, context, decision, false, nil)
    end
    task = Collavre::Task.where(agent: @agent, status: "suspended").order(:id).last
    assert_equal deadline, task.resume_not_before
    assert_equal context["comment"], task.trigger_event_payload["comment"]
    assert_no_difference -> { Collavre::Task.count } do
      assert_nil Collavre::Quota::PendingDispatch.call(@agent, "comment_created", context, deadline)
    end
  end

  test "quota exhaustion notice is translated and does not dispatch another turn" do
    @task.update!(creative: creatives(:tshirt))
    assert_no_enqueued_jobs(only: Collavre::AiAgentJob) do
      Collavre::Quota::Notice.exhausted!(@task)
    end
    notice = @task.creative.comments.order(:id).last
    assert_nil notice.user_id
    assert_equal I18n.t("collavre.quota.exhausted", locale: @agent.locale.presence || :en), notice.content
    @task.update!(creative: nil)
    assert_no_difference -> { Collavre::Comment.count } do
      Collavre::Quota::Notice.exhausted!(@task)
    end
  end

  test "a previous worker failure cannot suspend a newer execution" do
    @task.update!(trigger_event_payload: { "execution_generation" => "new" })
    assert_nil Collavre::Quota::Recovery.suspend!(@task, Collavre::Quota::ExceededError.new, expected_generation: "old")
    assert_equal "running", @task.reload.status
    assert_nil @agent.reload.quota_blocked_until
    assert_equal 0, @agent.quota_retry_count
  end

  private

  def recover(reset = nil)
    Collavre::Quota::Recovery.suspend!(@task, Collavre::Quota::ExceededError.new(reset_at: reset))
  end
end
