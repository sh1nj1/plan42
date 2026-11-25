require "test_helper"

module Collavre
  class SolidQueueWorkerWatchdogJobTest < ActiveJob::TestCase
    setup do
      @previous_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @killed = []
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

    private

    def perform_watchdog(kill: ->(signal, pid) { @killed << [ signal, pid ] })
      Rails.stub(:cache, @cache) do
        ::Process.stub(:kill, kill) { SolidQueueWorkerWatchdogJob.perform_now }
      end
    end

    def register_worker(queues:, pool_size:, hostname: Socket.gethostname, heartbeat: Time.current, created: 10.minutes.ago)
      SolidQueue::Process.create!(kind: "Worker", name: SecureRandom.uuid, pid: rand(100_000..999_999),
        hostname: hostname, last_heartbeat_at: heartbeat, created_at: created,
        metadata: { queues: queues, pool_size: pool_size })
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
