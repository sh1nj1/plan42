require "test_helper"

module Collavre
  class SolidQueueRetryRecoveryTest < ActiveJob::TestCase
    setup do
      @job = SolidQueue::Job.enqueue(AiAgentJob.new(users(:ai_bot).id, "comment_created", {}))
      @job.ready_execution.destroy!
      @failure = SolidQueue::FailedExecution.create!(job: @job, exception: RuntimeError.new("interrupted"))
      @task = Task.create!(name: "Retry", agent: users(:ai_bot), status: "running",
        trigger_event_payload: Orchestration::ExecutionFence.stamp({}, job_id: @job.active_job_id))
    end

    test "failed queue preparation rolls back the reclaim and retains the failure" do
      @failure.stub(:job, @job) do
        @job.stub(:prepare_for_execution, -> { raise "queue unavailable" }) do
          assert_raises(RuntimeError) { @failure.retry }
        end
      end
      assert_equal "running", @task.reload.status
      assert @failure.reload.persisted?
      assert_not_nil Orchestration::ExecutionFence.generation(@task)
    end

    test "failed bulk dispatch rolls back reclamation" do
      SolidQueue::Job.stub(:dispatch_all, ->(*) { raise "queue unavailable" }) do
        assert_raises(RuntimeError) { SolidQueue::FailedExecution.retry_all([ @job ]) }
      end
      assert_equal "running", @task.reload.status
      assert @failure.reload.persisted?
    end

    test "retry of another job class does not reclaim an AI task" do
      @job.update!(class_name: "Collavre::RecoverInterruptedTasksJob")
      @failure.retry
      assert_equal "running", @task.reload.status
      assert @job.reload.ready_execution
    end

    test "bulk retry ignores unrelated jobs and jobs without a failed execution" do
      @job.update!(class_name: "Collavre::RecoverInterruptedTasksJob")
      SolidQueue::FailedExecution.retry_all([ @job ])
      assert_equal "running", @task.reload.status
      @job.update!(class_name: "Collavre::AiAgentJob")
      SolidQueue::FailedExecution.retry_all([ @job ])
      assert_equal "running", @task.reload.status
    end

    test "both retry paths preserve channel turns that may have been delivered" do
      %w[started completed].each do |state|
        payload = @task.trigger_event_payload.merge("channel_handoff" => {
          "generation" => Orchestration::ExecutionFence.generation(@task), "state" => state
        })
        @task.update!(status: "delegated", trigger_event_payload: payload)
        SolidQueue::FailedExecution.transaction(requires_new: true) do
          @failure.reload.retry
          assert_equal "delegated", @task.reload.status
          raise ActiveRecord::Rollback
        end
        SolidQueue::FailedExecution.transaction(requires_new: true) do
          SolidQueue::FailedExecution.retry_all([ @job ])
          assert_equal "delegated", @task.reload.status
          raise ActiveRecord::Rollback
        end
      end
    end
  end
end
