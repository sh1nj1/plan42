require "test_helper"
require "tmpdir"

module Collavre
  class SplitDatabaseRecoveryTest < ActiveJob::TestCase
    self.use_transactional_tests = false
    SimulatedWorkerExit = Class.new(Exception)

    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @queue_connection_name = SolidQueue::Record.connection_specification_name
      schema = SolidQueue::Record.connection.select_values(
        "SELECT sql FROM sqlite_master WHERE name LIKE 'solid_queue_%' AND sql IS NOT NULL ORDER BY type DESC"
      )
      @queue_dir = Dir.mktmpdir("split-queue-recovery")
      SolidQueue::Record.establish_connection(adapter: "sqlite3", database: File.join(@queue_dir, "queue.sqlite3"))
      schema.each { |sql| SolidQueue::Record.connection.execute(sql) }
      @agent = users(:ai_bot)
      @creative = creatives(:tshirt)
      @topic = Topic.create!(creative: @creative, user: users(:one), name: "Split database recovery")
      @task = Task.create!(name: "Interrupted turn", agent: @agent, creative: @creative, topic_id: @topic.id, status: "running")
      @execution = AiAgentJob.new(@agent.id, "comment_created", {
        "creative" => { "id" => @creative.id }, "topic" => { "id" => @topic.id }
      })
      @queue_job = SolidQueue::Job.enqueue(@execution)
      @task.update!(trigger_event_payload: Orchestration::ExecutionFence.stamp({}, job_id: @execution.job_id))
      @queue_job.ready_execution.destroy!
      @failure = SolidQueue::FailedExecution.create!(job: @queue_job,
        exception: SolidQueue::Processes::ProcessMissingError.new)
    end

    teardown do
      @task&.destroy!
      @topic&.destroy!
      RetiredTaskExecution.where(execution_job_id: @execution&.job_id).delete_all
      SolidQueue::Record.remove_connection
      SolidQueue::Record.connection_specification_name = @queue_connection_name
      FileUtils.remove_entry(@queue_dir) if @queue_dir
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    test "queue rollback cannot undo the task fence and a direct stale dispatch cannot create another turn" do
      interrupt_after_primary_commit
      complete_replacement
      @task.destroy!
      Workflow::TaskAdmission.stub(:permitted?, ->(*) { flunk "retired execution reached dispatch" }) do
        assert_no_difference "Task.count" do
          AiAgentJob.execute(@queue_job.reload.arguments)
        end
      end
    end

    test "individual retry discards the old failure after split commit and replacement completion" do
      interrupt_after_primary_commit
      complete_replacement
      @failure.reload.retry
      assert_not SolidQueue::Job.exists?(@queue_job.id)
      assert_not SolidQueue::ReadyExecution.exists?(job_id: @queue_job.id)
      assert_equal "done", @task.reload.status
    end

    test "bulk retry discards retired jobs and still dispatches unrelated jobs" do
      interrupt_after_primary_commit
      complete_replacement
      other_job = SolidQueue::Job.enqueue(RecoverInterruptedTasksJob.new)
      other_job.ready_execution.destroy!
      SolidQueue::FailedExecution.create!(job: other_job, exception: RuntimeError.new("retry me"))
      SolidQueue::FailedExecution.retry_all([ @queue_job, other_job ])
      assert_not SolidQueue::Job.exists?(@queue_job.id)
      assert SolidQueue::ReadyExecution.exists?(job_id: other_job.id)
      assert_equal "done", @task.reload.status
    end

    test "a failed primary transaction commits neither suspension nor a tombstone" do
      RetiredTaskExecution.stub(:create_or_find_by!, ->(**) { raise SimulatedWorkerExit }) do
        assert_raises(SimulatedWorkerExit) { RecoverInterruptedTasksJob.perform_now }
      end
      assert_equal "running", @task.reload.status
      assert_not RetiredTaskExecution.exists?(execution_job_id: @execution.job_id)
      assert @failure.reload.persisted?
    end

    %w[individual bulk].product(%w[running delegated]).each do |mode, status|
      test "#{mode} retry of #{status} split commit is reconciled by the periodic sweep" do
        @task.update!(status: status,
          trigger_event_payload: Orchestration::ExecutionFence.pending_handoff(@task.trigger_event_payload))
        # A manual retry is valid for application failures too, not only dead owners.
        @failure.update!(error: { "exception_class" => "RuntimeError", "message" => "provider error" })
        assert_raises(SimulatedWorkerExit) do
          SolidQueue::FailedExecution.transaction do
            if mode == "individual"
              @failure.retry
            else
              SolidQueue::FailedExecution.retry_all([ @queue_job ])
            end
            assert_equal 0, Task.connection.open_transactions
            assert_equal "pending", @task.reload.status
            raise SimulatedWorkerExit
          end
        end
        assert SolidQueue::FailedExecution.exists?(@failure.id)
        assert_not SolidQueue::ReadyExecution.exists?(job_id: @queue_job.id)
        assert_nil Orchestration::ExecutionFence.generation(@task)

        assert_no_difference "Task.count" do
          2.times { RecoverInterruptedTasksJob.perform_now }
        end
        assert_not SolidQueue::FailedExecution.exists?(@failure.id)
        assert_equal 1, SolidQueue::ReadyExecution.where(job_id: @queue_job.id).count
        assert_equal @execution.job_id, @task.reload.trigger_event_payload["execution_job_id"]
        assert_equal 0, @task.resume_count
        assert Workflow::TaskAdmission.start!(@task, execution_job_id: @execution.job_id)
        assert_not_nil Orchestration::ExecutionFence.generation(@task.reload)
      end
    end

    test "a new failure before admission is not mistaken for an unfinished retry" do
      @failure.retry
      assert_equal "pending", @task.reload.status
      assert_nil Orchestration::ExecutionFence.generation(@task)
      @queue_job.reload.ready_execution.destroy!
      new_failure = SolidQueue::FailedExecution.create!(job: @queue_job, exception: RuntimeError.new("admission failed"))
      assert_not_equal @failure.id, new_failure.id
      2.times { RecoverInterruptedTasksJob.perform_now }
      assert new_failure.reload.persisted?
      assert_not SolidQueue::ReadyExecution.exists?(job_id: @queue_job.id)

      # A later explicit retry creates a new intent even though admission never ran.
      SolidQueue::FailedExecution.transaction do
        new_failure.retry
        raise ActiveRecord::Rollback
      end
      assert_equal new_failure.id, @task.reload.trigger_event_payload[Orchestration::SolidQueueRetryRecovery::RETRY_FAILURE_KEY]
      RecoverInterruptedTasksJob.perform_now
      assert_not SolidQueue::FailedExecution.exists?(new_failure.id)
      assert SolidQueue::ReadyExecution.exists?(job_id: @queue_job.id)
    end

    test "pending tasks with an intact generation are not reclaimed retry intents" do
      @task.update!(status: "pending")
      RecoverInterruptedTasksJob.perform_now
      assert @failure.reload.persisted?
      assert_not SolidQueue::ReadyExecution.exists?(job_id: @queue_job.id)
    end

    private

    def interrupt_after_primary_commit
      assert_not_equal Task.connection_pool, SolidQueue::Job.connection_pool
      lock = @failure.method(:with_lock)
      interrupt = lambda do |&block|
        next lock.call(&block) if Task.connection.open_transactions.positive?

        lock.call do
          block.call
          assert_equal 0, Task.connection.open_transactions
          assert_equal "suspended", @task.reload.status
          raise SimulatedWorkerExit
        end
      end
      SolidQueue::Job.stub(:find_by, @queue_job) do
        @queue_job.stub(:failed_execution, @failure) do
          @failure.stub(:with_lock, interrupt) do
            assert_raises(SimulatedWorkerExit) { RecoverInterruptedTasksJob.perform_now }
          end
        end
      end
      assert_equal "suspended", @task.reload.status
      assert RetiredTaskExecution.exists?(execution_job_id: @execution.job_id)
      assert SolidQueue::FailedExecution.exists?(@failure.id)
    end

    def complete_replacement
      ResumeSuspendedTasksJob.perform_now(task_id: @task.id)
      @task.reload
      assert_equal "pending", @task.status
      assert_nil @task.trigger_event_payload["execution_job_id"]
      assert Workflow::TaskAdmission.start!(@task, execution_job_id: "replacement")
      @task.update!(status: "done")
    end
  end
end
