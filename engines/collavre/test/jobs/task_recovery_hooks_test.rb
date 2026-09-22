require "test_helper"

module Collavre
  class TaskRecoveryHooksTest < ActiveJob::TestCase
    setup do
      @previous_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

    test "Solid Queue worker boot schedules recovery through its installed lifecycle hook" do
      assert_enqueued_with(job: RecoverInterruptedTasksJob) { recovery_hook(:start).call }
    end

    test "worker stop schedules recovery after drain without suspending live tasks" do
      task = Task.create!(agent: users(:ai_bot), name: "Still executing", status: "running")
      freeze_time do
        assert_enqueued_with(job: RecoverInterruptedTasksJob, at: (SolidQueue.shutdown_timeout + 1.second).from_now) do
          pool = Minitest::Mock.new
          pool.expect :shutdown, true
          pool.expect :wait_for_termination, true, [ nil ]
          worker = Struct.new(:queues, :pool).new([ "ai_agents" ], pool)
          recovery_hook(:stop).call(worker)
          pool.verify
        end
      end
      assert_equal "running", task.reload.status
    end

    test "a failed recovery enqueue still drains the pool before deregistration" do
      pool = Minitest::Mock.new
      pool.expect :shutdown, true
      pool.expect :wait_for_termination, true, [ nil ]
      worker = Struct.new(:queues, :pool).new([ "ai_agents" ], pool)
      RecoverInterruptedTasksJob.stub(:set, ->(**) { raise ActiveJob::EnqueueError, "queue unavailable" }) do
        assert_raises(ActiveJob::EnqueueError) { recovery_hook(:stop).call(worker) }
      end
      pool.verify
    end

    test "stop hook preserves default draining for unrelated queues" do
      worker = Struct.new(:queues, :pool).new([ "default" ], nil)
      assert_enqueued_with(job: RecoverInterruptedTasksJob) { recovery_hook(:stop).call(worker) }
    end

    test "actual worker shutdown cannot deregister while its execution pool is still running" do
      worker = SolidQueue::Worker.new(queues: [ "ai_agents" ], threads: 1)
      entered = Queue.new
      finish = Queue.new
      deregistered = Queue.new
      draining = Queue.new
      original_shutdown = worker.pool.method(:shutdown)
      worker.pool.define_singleton_method(:shutdown) { original_shutdown.call.tap { draining << true } }
      execution = Object.new
      execution.define_singleton_method(:perform) { entered << true; finish.pop }
      worker.define_singleton_method(:deregister) { deregistered << true }
      worker.pool.post(execution)
      Timeout.timeout(5) { entered.pop }

      stopping = Thread.new { worker.send(:run_callbacks, :shutdown) { worker.send(:shutdown) } }
      Timeout.timeout(5) { draining.pop }
      assert stopping.alive?, "Shutdown must wait for the original execution"
      assert deregistered.empty?, "A live execution must not be released to another worker"
      finish << true
      Timeout.timeout(5) { stopping.value }
      assert_equal true, deregistered.pop
    ensure
      finish << true if finish
      stopping&.join(1)
      worker&.pool&.shutdown
    end

    test "recovery sweeps are configured in every server environment" do
      config = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
      %w[production desktop development].each do |environment|
        assert_equal "Collavre::RecoverInterruptedTasksJob", config.dig(environment, "interrupted_task_recovery", "class")
        assert_equal "every minute", config.dig(environment, "interrupted_task_recovery", "schedule")
        assert_equal "Collavre::OfflineTaskSweepJob", config.dig(environment, "offline_task_recovery", "class")
      end
    end

    private

    def recovery_hook(event)
      SolidQueue::Worker.lifecycle_hooks.fetch(event).find do |hook|
        hook.source_location.first.end_with?("collavre/config/initializers/task_recovery.rb")
      end.tap { |hook| assert hook, "Recovery hook must be installed on the real Solid Queue worker" }
    end
  end
end
