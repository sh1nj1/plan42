# frozen_string_literal: true

module Collavre
  # Restarts Solid Queue workers whose poll loop has wedged while their
  # heartbeat thread keeps them registered. Observed after a Postgres restart:
  # the ai_agents worker stayed alive with spare threads but never claimed
  # again, so the supervisor never replaced it and every agent turn queued up.
  #
  # A worker is wedged when a queue it serves holds a ready execution older
  # than STALL_THRESHOLD while that worker still has spare capacity — a healthy
  # worker polls every fraction of a second and would have claimed it. Only
  # workers on this host are signalled; SIGKILL is used because a wedged poll
  # loop never handles TERM. The supervisor forks a replacement and fails the
  # killed worker's claims, which RecoverInterruptedTasksJob then resumes.
  class SolidQueueWorkerWatchdogJob < ApplicationJob
    queue_as :default

    STALL_THRESHOLD = 3.minutes

    def perform
      return unless defined?(SolidQueue::ReadyExecution)

      stalled = stalled_queues
      return [] if stalled.empty?

      wedged_workers(stalled).filter_map { |process| restart(process) }
    end

    private

    def stalled_queues
      SolidQueue::ReadyExecution.where(created_at: ...STALL_THRESHOLD.ago)
        .where.not(queue_name: SolidQueue::Pause.select(:queue_name))
        .distinct.pluck(:queue_name)
    end

    def wedged_workers(stalled)
      SolidQueue::Process.where(kind: "Worker", hostname: Socket.gethostname)
        .where(last_heartbeat_at: SolidQueue.process_alive_threshold.ago..)
        .where(created_at: ...STALL_THRESHOLD.ago)
        .where.not(pid: ::Process.pid)
        .select { |process| serves_any?(process, stalled) && spare_capacity?(process) }
    end

    def serves_any?(process, queues)
      patterns = process.metadata.fetch("queues", "").split(",")
      queues.any? { |queue| patterns.any? { |pattern| File.fnmatch?(pattern, queue) } }
    end

    def spare_capacity?(process)
      pool_size = process.metadata["pool_size"].to_i
      pool_size.positive? && SolidQueue::ClaimedExecution.where(process_id: process.id).count < pool_size
    end

    def restart(process)
      Rails.logger.warn(
        "[SolidQueueWorkerWatchdog] Killing wedged worker pid=#{process.pid} " \
        "name=#{process.name} queues=#{process.metadata["queues"]}"
      )
      ::Process.kill(:KILL, process.pid)
      process
    rescue Errno::ESRCH, Errno::EPERM => e
      Rails.logger.warn("[SolidQueueWorkerWatchdog] Could not signal pid=#{process.pid}: #{e.class}")
      nil
    end
  end
end
