require "test_helper"

class QuotaDurableReservationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "rolling back the agent block leaves no suspension or scheduled wakeup" do
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    agent = users(:ai_bot)
    task = Collavre::Task.create!(name: "Rolled back quota", agent: agent, status: "running", trigger_event_payload: {})
    assert_no_enqueued_jobs(only: Collavre::ResumeSuspendedTasksJob) do
      Collavre::Task.transaction do
        Collavre::Quota::Recovery.suspend!(task, Collavre::Quota::ExceededError.new(reset_at: 1.hour.from_now))
        raise ActiveRecord::Rollback
      end
    end
    assert_equal "running", task.reload.status
    assert_equal 0, agent.reload.quota_retry_count
    assert_nil agent.quota_blocked_until
  ensure
    task&.destroy!
    ActiveJob::Base.queue_adapter = previous
  end

  test "quota wakeup survives serialization and runs once after process state is discarded" do
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    agent = users(:ai_bot)
    task = Collavre::Task.create!(name: "Durable quota", agent: agent, status: "running", trigger_event_payload: {})
    Collavre::Quota::Recovery.suspend!(task, Collavre::Quota::ExceededError.new(reset_at: 1.hour.from_now))
    deadline = task.reload.resume_not_before
    job = SolidQueue::Job.where(class_name: "Collavre::ResumeSuspendedTasksJob").order(:id).last
    assert_not_nil job
    assert_equal deadline.to_i, job.scheduled_at.to_i
    assert SolidQueue::ScheduledExecution.exists?(job_id: job.id)
    serialized = JSON.parse(JSON.generate(job.arguments))
    task_id = task.id
    task = nil
    ActiveJob::Base.queue_adapter = :test

    travel_to deadline + 1 do
      ActiveJob::Base.execute(serialized)
      assert_equal 1, Collavre::Task.find(task_id).resume_count
      assert_no_enqueued_jobs(only: Collavre::AiAgentJob) { ActiveJob::Base.execute(serialized) }
    end
  ensure
    job&.destroy!
    Collavre::Task.find_by(id: task_id || task&.id)&.destroy!
    agent&.update_columns(quota_blocked_until: nil, quota_retry_count: 0, quota_retry_exhausted: false)
    ActiveJob::Base.queue_adapter = previous
  end

  test "serialized sibling wakeups cannot bypass the persisted probe election" do
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :solid_queue
    agent = users(:ai_bot)
    tasks = 2.times.map do |i|
      Collavre::Task.create!(name: "Durable probe #{i}", agent: agent, status: "running",
                            trigger_event_payload: Collavre::Orchestration::ExecutionFence.stamp({}))
    end
    jobs = tasks.map do |task|
      Collavre::Quota::Recovery.suspend!(task, Collavre::Quota::ExceededError.new)
      SolidQueue::Job.where(class_name: "Collavre::ResumeSuspendedTasksJob").order(:id).last
    end
    deadline = agent.reload.quota_blocked_until
    ids = tasks.map(&:id)
    serialized = jobs.map { |job| JSON.parse(JSON.generate(job.arguments)) }
    tasks = agent = nil
    ActiveJob::Base.queue_adapter = :test

    travel_to deadline + 1 do
      # Reverse order and replay after discarding every application instance.
      2.times { serialized.reverse_each { |arguments| ActiveJob::Base.execute(arguments) } }
      probe, sibling = ids.map { |id| Collavre::Task.find(id) }
      assert_equal "pending", probe.status
      assert_equal "suspended", sibling.status
      assert_equal 0, sibling.resume_count
      assert_equal probe.id, probe.agent.quota_probe_task_id
      probe.update!(status: "running", trigger_event_payload: Collavre::Orchestration::ExecutionFence.stamp({}))
      Collavre::Quota::Recovery.guard!(probe)
      probe = Collavre::Task.find(probe.id)
      Collavre::Quota::Recovery.succeeded!(probe.agent, task: probe)
      ActiveJob::Base.execute(serialized.last)
      assert_equal "pending", sibling.reload.status
    end
  ensure
    jobs&.each(&:destroy!)
    Collavre::Task.where(id: ids || tasks&.map(&:id)).destroy_all
    users(:ai_bot).update_columns(quota_blocked_until: nil, quota_retry_count: 0, quota_retry_exhausted: false,
                                 quota_probe_task_id: nil, quota_probe_generation: nil)
    ActiveJob::Base.queue_adapter = previous
  end
end
