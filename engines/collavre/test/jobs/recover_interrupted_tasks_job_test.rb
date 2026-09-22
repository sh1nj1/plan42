require "test_helper"

module Collavre
  class RecoverInterruptedTasksJobTest < ActiveJob::TestCase
    setup do
      @previous_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

    setup do
      @agent = users(:ai_bot)
      @job = SolidQueue::Job.enqueue(AiAgentJob.new(@agent.id, "comment_created", {}))
      @task = Task.create!(name: "Interrupted turn", agent: @agent, status: "running",
        trigger_event_payload: { "execution_job_id" => @job.active_job_id })
      @process = SolidQueue::Process.register(kind: "Worker", name: SecureRandom.uuid, pid: 123,
        hostname: "worker.example.test")
      @job.ready_execution.destroy!
      @claim = SolidQueue::ClaimedExecution.create!(job: @job, process: @process)
    end

    test "reclaimed pending work with a live claim is never redispatched" do
      @task.update!(status: "pending")
      SolidQueue::FailedExecution.create!(job: @job, exception: RuntimeError.new("stale failure"))
      RecoverInterruptedTasksJob.perform_now
      assert @job.reload.failed_execution
      assert_not @job.ready_execution
    end

    test "reclaimed pending work is rechecked under lock before retry" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      @task.update!(status: "pending")
      SolidQueue::Job.stub(:find_by, ->(**) { @task.update!(status: "cancelled"); @job.reload }) do
        RecoverInterruptedTasksJob.perform_now
      end
      assert @job.reload.failed_execution
      assert_not @job.ready_execution
    end

    test "boot never recovers a different healthy worker's running task" do
      2.times { RecoverInterruptedTasksJob.perform_now }
      assert_equal "running", @task.reload.status
      assert_equal @process.id, @claim.reload.process_id
      assert_no_enqueued_jobs only: AiAgentJob
    end

    test "expired heartbeat alone is not proof until Solid Queue prunes the owner" do
      @process.update!(last_heartbeat_at: (SolidQueue.process_alive_threshold + 1.minute).ago)
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status

      @process.prune
      assert_equal "SolidQueue::Processes::ProcessPrunedError", @job.reload.failed_execution.exception_class
      assert_enqueued_with(job: AiAgentJob, args: [ @task ]) { RecoverInterruptedTasksJob.perform_now }
      assert_equal "pending", @task.reload.status
      assert_equal 1, @task.resume_count
      assert_equal "server_restart", @task.trigger_event_payload.dig("resume_context", "reason")
    end

    test "dead owner recovery and duplicate boot keep the same task and enqueue once" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      assert_no_difference "Task.count" do
        assert_enqueued_jobs 1, only: AiAgentJob do
          2.times { RecoverInterruptedTasksJob.perform_now }
        end
      end
      assert_equal "pending", @task.reload.status
      assert_equal 1, @task.resume_count
      assert_equal 1, RetiredTaskExecution.where(execution_job_id: @job.active_job_id).count
    end

    test "recovery retires the failed job before enqueueing its replacement" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      failure = @job.reload.failed_execution
      stale_failure = SolidQueue::FailedExecution.includes(:job).find(failure.id)
      resume = Orchestration::TaskResumer.method(:resume!)

      Orchestration::TaskResumer.stub(:resume!, ->(task) {
        assert_not SolidQueue::Job.exists?(@job.id)
        assert_not SolidQueue::FailedExecution.exists?(failure.id)
        resume.call(task)
      }) do
        assert_enqueued_jobs 1, only: AiAgentJob do
          RecoverInterruptedTasksJob.perform_now
        end
      end

      assert_raises(ActiveRecord::RecordNotFound) { stale_failure.retry }
      assert_not SolidQueue::ReadyExecution.exists?(job_id: @job.id)
      assert_equal "pending", @task.reload.status
    end

    test "a manual retry winning before recovery preserves the original ready job" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      @job.reload.retry

      assert_no_enqueued_jobs only: AiAgentJob do
        RecoverInterruptedTasksJob.perform_now
      end
      assert SolidQueue::ReadyExecution.exists?(job_id: @job.id)
      assert_equal "pending", @task.reload.status
    end

    test "recovery also retires a failed job when the resume limit escalates the task" do
      @task.update!(resume_count: Orchestration::TaskResumer::MAX_RESUMES)
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)

      assert_no_enqueued_jobs only: AiAgentJob do
        RecoverInterruptedTasksJob.perform_now
      end
      assert_equal "escalated", @task.reload.status
      assert RetiredTaskExecution.exists?(execution_job_id: @job.active_job_id)
      assert_not SolidQueue::Job.exists?(@job.id)
    end

    test "restart recovery keeps delivered partial output and action history in the resumed context" do
      creative = creatives(:tshirt)
      topic = Topic.create!(creative: creative, user: users(:one), name: "Partial recovery")
      @task.update!(creative_id: creative.id, topic_id: topic.id)
      partial = Comment.create!(creative: creative, topic: topic, user: @agent, task: @task,
        content: "The first part is complete.", skip_dispatch: true)
      action = @task.task_actions.create!(action_type: "tool_result", status: "done", payload: { "result" => "saved" })
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      RecoverInterruptedTasksJob.perform_now
      assert_equal "pending", @task.reload.status
      assert_equal "The first part is complete.", @task.trigger_event_payload.dig("resume_context", "partial_reply")
      assert_includes @task.trigger_event_payload.dig("resume_context", "actions"), "tool_result (done)"
      assert_equal "The first part is complete.", partial.reload.content
      assert_nil partial.task_id
      assert_equal @task.id, action.reload.task_id
    end

    test "a surviving claim always wins over a stale failure record" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      SolidQueue::ClaimedExecution.create!(job: @job, process: @process)
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status
    end

    test "a task that completed between owner lookup and its row lock is not suspended" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      SolidQueue::Job.stub(:find_by, ->(**) { @task.update!(status: "done"); @job.reload }) do
        RecoverInterruptedTasksJob.perform_now
      end
      assert_equal "done", @task.reload.status
      assert_no_enqueued_jobs only: AiAgentJob
    end

    test "a task that acquired another execution owner before locking is not suspended" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      SolidQueue::Job.stub(:find_by, ->(**) {
        @task.update!(trigger_event_payload: { "execution_job_id" => "new-owner" })
        @job.reload
      }) { RecoverInterruptedTasksJob.perform_now }
      assert_equal "running", @task.reload.status
      assert_no_enqueued_jobs only: AiAgentJob
    end

    test "a suspension that loses its transition leaves the failure retryable" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      Orchestration::TaskResumer.stub(:suspend!, nil) do
        assert_no_enqueued_jobs only: AiAgentJob do
          RecoverInterruptedTasksJob.perform_now
        end
      end
      assert SolidQueue::Job.exists?(@job.id)
      assert @job.reload.failed_execution
      assert_not RetiredTaskExecution.exists?(execution_job_id: @job.active_job_id)
      assert_equal "running", @task.reload.status
    end

    test "a failure concurrently removed by queue retry does not authorize recovery" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      failure = @job.reload.failed_execution
      SolidQueue::FailedExecution.where(id: failure.id).delete_all
      SolidQueue::Job.stub(:find_by, @job) do
        @job.stub(:failed_execution, failure) { RecoverInterruptedTasksJob.perform_now }
      end
      assert_equal "running", @task.reload.status
    end

    test "a supervisor-recorded fork exit resumes the interrupted task once" do
      pid = Process.fork { Process.exit!(1) }
      _, status = Process.wait2(pid)
      @claim.failed_with(SolidQueue::Processes::ProcessExitError.new(status))
      assert_enqueued_jobs 1, only: AiAgentJob do
        2.times { RecoverInterruptedTasksJob.perform_now }
      end
      assert_equal "pending", @task.reload.status
    end

    test "async worker thread termination follows the same durable recovery path" do
      @claim.failed_with(SolidQueue::Processes::ThreadTerminatedError.new("stopped-worker"))
      RecoverInterruptedTasksJob.perform_now
      assert_equal "pending", @task.reload.status
      assert_equal 1, @task.resume_count
    end

    test "ordinary provider failure does not authorize restart recovery" do
      @claim.failed_with(RuntimeError.new("provider failed"))
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status
    end

    test "online channel work resumes once when its worker dies before delegation" do
      @agent.update!(llm_model: "claude-code", llm_vendor: "anthropic")
      AgentSubscription.create!(agent: @agent, token: "live-channel")
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)

      assert_no_difference "Task.count" do
        assert_enqueued_jobs 1, only: AiAgentJob do
          2.times { RecoverInterruptedTasksJob.perform_now }
        end
      end
      assert_equal "pending", @task.reload.status
      assert_equal 1, @task.resume_count
      assert_equal "server_restart", @task.trigger_event_payload.dig("resume_context", "reason")
    end

    test "channel work with a healthy execution owner is not recovered" do
      @agent.update!(llm_model: "claude-code", llm_vendor: "anthropic")
      AgentSubscription.create!(agent: @agent, token: "healthy-channel")
      assert_no_enqueued_jobs only: AiAgentJob do
        RecoverInterruptedTasksJob.perform_now
      end
      assert_equal "running", @task.reload.status
      assert_equal @process.id, @claim.reload.process_id
    end

    test "online delegated channel work recovers once only before broadcast starts" do
      prepare_channel_handoff("pending")
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      assert_no_difference "Task.count" do
        assert_enqueued_jobs 1, only: AiAgentJob do
          2.times { RecoverInterruptedTasksJob.perform_now }
        end
      end
      assert_equal "pending", @task.reload.status
      assert_equal 1, @task.resume_count
      assert_not SolidQueue::Job.exists?(@job.id)
    end

    test "started and completed broadcasts are never replayed after owner failure" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      %w[started completed].each do |state|
        prepare_channel_handoff(state)
        assert_no_enqueued_jobs only: AiAgentJob do
          RecoverInterruptedTasksJob.perform_now
        end
        assert_equal "delegated", @task.reload.status
        assert SolidQueue::Job.exists?(@job.id)
      end
    end

    test "pending handoff with a healthy owner or mismatched generation is not recovered" do
      prepare_channel_handoff("pending")
      assert_no_enqueued_jobs(only: AiAgentJob) { RecoverInterruptedTasksJob.perform_now }
      assert_equal "delegated", @task.reload.status
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      @task.update!(trigger_event_payload: @task.trigger_event_payload.merge("execution_generation" => "new-generation"))
      assert_no_enqueued_jobs(only: AiAgentJob) { RecoverInterruptedTasksJob.perform_now }
      assert_equal "delegated", @task.reload.status
    end

    test "handoff starting between owner lookup and task lock prevents recovery" do
      prepare_channel_handoff("pending")
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      SolidQueue::Job.stub(:find_by, ->(**) { prepare_channel_handoff("started"); @job.reload }) do
        assert_no_enqueued_jobs(only: AiAgentJob) { RecoverInterruptedTasksJob.perform_now }
      end
      assert_equal "delegated", @task.reload.status
    end

    test "delegated channel work belongs to the offline policy even after worker death" do
      @agent.update!(llm_model: "claude-code", llm_vendor: "anthropic")
      AgentSubscription.create!(agent: @agent, token: "delegated-channel")
      @task.update!(status: "delegated")
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      assert_no_enqueued_jobs only: AiAgentJob do
        RecoverInterruptedTasksJob.perform_now
      end
      assert_equal "delegated", @task.reload.status
    end

    test "delegation between owner lookup and row lock prevents restart recovery" do
      @agent.update!(llm_model: "claude-code", llm_vendor: "anthropic")
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      SolidQueue::Job.stub(:find_by, ->(**) { @task.update!(status: "delegated"); @job.reload }) do
        assert_no_enqueued_jobs only: AiAgentJob do
          RecoverInterruptedTasksJob.perform_now
        end
      end
      assert_equal "delegated", @task.reload.status
    end

    test "legacy tasks and absent queue jobs are left to existing stuck recovery" do
      @task.update!(trigger_event_payload: {})
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status
      @task.update!(trigger_event_payload: { "execution_job_id" => "missing-job" })
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status
    end

    test "released ready job and finished job are not failed owners" do
      @claim.release
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status
      @job.update!(finished_at: Time.current)
      RecoverInterruptedTasksJob.perform_now
      assert_equal "running", @task.reload.status
    end

    test "a late completion wins before the recovery row lock" do
      @claim.failed_with(SolidQueue::Processes::ProcessMissingError.new)
      @task.update!(status: "done")
      RecoverInterruptedTasksJob.perform_now
      assert_equal "done", @task.reload.status
      assert_no_enqueued_jobs only: AiAgentJob
    end
    private

    def prepare_channel_handoff(state)
      @agent.update!(llm_model: "claude-code", llm_vendor: "anthropic")
      AgentSubscription.find_or_create_by!(agent: @agent, token: "handoff-channel")
      @task.update!(status: "delegated", trigger_event_payload: {
        "execution_job_id" => @job.active_job_id, "execution_generation" => "attempt",
        "channel_handoff" => { "generation" => "attempt", "state" => state }
      })
    end
  end
end
