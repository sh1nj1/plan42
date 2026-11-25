require "test_helper"

module Collavre
  class SolidQueueWorkerWatchdogJobTest < ActiveJob::TestCase
    setup do
      @previous_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @killed = []
      @processes = {}
      @cache = ActiveSupport::Cache::MemoryStore.new
      freeze_time
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_queue_adapter }

    test "kills a live worker with spare capacity that leaves its queue stalled" do
      worker = register_worker(queues: "ai_agents", pool_size: 12)
      enqueue_ready("ai_agents", age: 4.minutes)

      assert_empty perform_watchdog
      travel 30.seconds
      assert_empty perform_watchdog
      travel 30.seconds
      assert_equal [ worker ], perform_watchdog
      assert_equal [ [ :KILL, worker.pid ] ], @killed
    end

    test "matches wildcard queue patterns" do
      register_worker(queues: "ai_*", pool_size: 2)
      enqueue_ready("ai_agents", age: 4.minutes)

      assert_empty perform_watchdog
      travel 1.minute
      assert_equal 1, perform_watchdog.size
    end

    test "leaves workers alone while ready work is still recent" do
      register_worker(queues: "ai_agents", pool_size: 12)
      enqueue_ready("ai_agents", age: 1.minute)

      assert_empty perform_watchdog
      assert_empty @killed
    end

    test "a saturated worker is busy, not wedged" do
      worker = register_worker(queues: "ai_agents", pool_size: 1)
      claim(worker, "ai_agents")
      enqueue_ready("ai_agents", age: 4.minutes)

      assert_empty perform_watchdog
    end

    test "ignores paused queues, other queues, other hosts, stale heartbeats and fresh workers" do
      enqueue_ready("ai_agents", age: 4.minutes)
      SolidQueue::Pause.create!(queue_name: "ai_agents")
      register_worker(queues: "ai_agents", pool_size: 12)
      assert_empty perform_watchdog

      SolidQueue::Pause.delete_all
      SolidQueue::Process.delete_all
      register_worker(queues: "default", pool_size: 3)
      register_worker(queues: "ai_agents", pool_size: 12, hostname: "other-host")
      register_worker(queues: "ai_agents", pool_size: 12, heartbeat: 10.minutes.ago)
      register_worker(queues: "ai_agents", pool_size: 12, created: 1.minute.ago)
      assert_empty perform_watchdog
      assert_empty @killed
    end

    test "a worker that already exited is skipped without raising" do
      register_worker(queues: "ai_agents", pool_size: 12)
      enqueue_ready("ai_agents", age: 4.minutes)

      assert_empty perform_watchdog
      travel 1.minute
      assert_empty perform_watchdog(kill: ->(*) { raise Errno::ESRCH })
    end

    test "a worker that frees a slot during a backlog gets a new observation window" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      finished = claim(worker, "ai_agents")
      claim(worker, "ai_agents")
      enqueue_ready("ai_agents", age: 4.minutes)
      assert_empty perform_watchdog

      finished.destroy!
      travel 1.minute
      assert_empty perform_watchdog
      assert_empty @killed
    end

    test "a new claim resets the observation even when the claim count is unchanged" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      finished = claim(worker, "ai_agents")
      enqueue_ready("ai_agents", age: 4.minutes)
      assert_empty perform_watchdog

      finished.destroy!
      claim(worker, "ai_agents")
      travel 1.minute
      assert_empty perform_watchdog
      assert_empty @killed

      travel 1.minute
      assert_equal [ worker ], perform_watchdog
    end

    test "replacing the oldest ready execution resets the observation" do
      register_worker(queues: "ai_agents", pool_size: 2)
      first = enqueue_ready("ai_agents", age: 5.minutes)
      enqueue_ready("ai_agents", age: 4.minutes)
      assert_empty perform_watchdog

      first.ready_execution.destroy!
      travel 1.minute
      assert_empty perform_watchdog
      assert_empty @killed
    end

    test "pausing a queue clears the observation" do
      register_worker(queues: "ai_agents", pool_size: 2)
      enqueue_ready("ai_agents", age: 4.minutes)
      assert_empty perform_watchdog

      pause = SolidQueue::Pause.create!(queue_name: "ai_agents")
      travel 1.minute
      assert_empty perform_watchdog
      pause.destroy!
      travel 1.minute
      assert_empty perform_watchdog
      assert_empty @killed
    end

    test "skips workers registered under an async supervisor" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      worker.supervisor.update!(kind: "Supervisor(async)", pid: worker.pid)
      assert_skips_stalled_worker
    end

    test "skips workers without a local supervisor registration" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      worker.supervisor.update!(hostname: "other-host")
      assert_skips_stalled_worker
    end

    test "skips a worker PID shared with its fork supervisor registration" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      worker.supervisor.update!(pid: worker.pid)
      assert_skips_stalled_worker
    end

    test "skips a PID that no longer belongs to the registered supervisor" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      @processes[worker.pid] = "1 solid-queue-worker(1.7.2): waiting"
      assert_skips_stalled_worker
    end

    test "skips a PID reused by another child of the same supervisor" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      @processes[worker.pid] = "#{worker.supervisor.pid} solid-queue-dispatcher(1.7.2): dispatching"
      assert_skips_stalled_worker
    end

    test "skips a PID absent from the OS process table" do
      worker = register_worker(queues: "ai_agents", pool_size: 2)
      @processes.delete(worker.pid)
      assert_skips_stalled_worker
    end

    private

    def assert_skips_stalled_worker
      enqueue_ready("ai_agents", age: 4.minutes)
      assert_empty perform_watchdog
      travel 1.minute
      assert_empty perform_watchdog
      assert_empty @killed
    end

    def perform_watchdog(kill: ->(signal, pid) { @killed << [ signal, pid ] })
      Rails.stub(:cache, @cache) do
        Open3.stub(:capture2, method(:process_listing)) do
          ::Process.stub(:kill, kill) { SolidQueueWorkerWatchdogJob.perform_now }
        end
      end
    end

    def process_listing(*arguments, **)
      output = @processes[arguments.last.to_i]
      [ output.to_s, Struct.new(:success?).new(output.present?) ]
    end

    def register_worker(queues:, pool_size:, hostname: Socket.gethostname, heartbeat: Time.current, created: 10.minutes.ago)
      supervisor = SolidQueue::Process.create!(kind: "Supervisor(fork)", name: SecureRandom.uuid,
        pid: 10_000 + @processes.size, hostname: hostname, last_heartbeat_at: heartbeat)
      worker = SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: 20_000 + @processes.size,
        supervisor: supervisor,
        hostname: hostname, last_heartbeat_at: heartbeat, created_at: created,
        metadata: { queues: queues, pool_size: pool_size })
      @processes[worker.pid] = "#{supervisor.pid} solid-queue-worker(1.7.2): waiting"
      worker
    end

    def enqueue_ready(queue, age:)
      job = SolidQueue::Job.enqueue(StuckDetectorJob.new.set(queue: queue))
      job.ready_execution.update!(created_at: age.ago)
      job
    end

    def claim(worker, queue)
      job = SolidQueue::Job.enqueue(StuckDetectorJob.new.set(queue: queue))
      job.ready_execution.destroy!
      SolidQueue::ClaimedExecution.create!(job: job, process: worker)
    end
  end
end
