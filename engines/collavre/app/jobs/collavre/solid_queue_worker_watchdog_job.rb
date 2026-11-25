# frozen_string_literal: true

require "open3"

module Collavre
  # Restarts Solid Queue workers whose poll loop has wedged while their
  # heartbeat thread keeps them registered. Observed after a Postgres restart:
  # the ai_agents worker stayed alive with spare threads but never claimed
  # again, so the supervisor never replaced it and every agent turn queued up.
  #
  # A restart requires an old ready execution, spare capacity, and unchanged
  # ready and claimed execution IDs across watchdog runs at least a minute apart.
  # Only verified local forked workers are signalled. The supervisor replaces a killed worker
  # and fails its claims, which RecoverInterruptedTasksJob then resumes.
  class SolidQueueWorkerWatchdogJob < ApplicationJob
    queue_as :default

    STALL_THRESHOLD = 3.minutes
    OBSERVATION_INTERVAL = 1.minute
    OBSERVATION_TTL = 3.minutes

    def perform
      return unless defined?(SolidQueue::ReadyExecution)

      cache_key = "solid_queue_worker_watchdog/#{Socket.gethostname}"
      previous = Rails.cache.read(cache_key) || {}
      observed = {}
      stalled = stalled_queues

      restarted = (stalled.empty? ? [] : local_workers).filter_map do |process|
        observe(process, stalled, previous, observed)
      end
      Rails.cache.write(cache_key, observed, expires_in: OBSERVATION_TTL)
      restarted
    end

    private

    def stalled_queues
      ready = SolidQueue::ReadyExecution.where.not(queue_name: SolidQueue::Pause.select(:queue_name))
      backlogged = ready.where(created_at: ...STALL_THRESHOLD.ago).select(:queue_name).distinct

      ready.where(queue_name: backlogged).group(:queue_name, :priority).minimum(:job_id)
        .sort_by { |(_, priority), _| priority }
        .each_with_object({}) { |((queue, priority), job_id), heads| heads[queue] ||= [ priority, job_id ] }
    end

    def local_workers
      SolidQueue::Process.where(kind: "Worker", hostname: Socket.gethostname)
        .where(last_heartbeat_at: SolidQueue.process_alive_threshold.ago..)
        .where(created_at: ...STALL_THRESHOLD.ago)
        .where.not(pid: ::Process.pid)
    end

    def observe(process, stalled, previous, observed)
      snapshot = stalled_snapshot(process, stalled)
      return unless snapshot

      identity = [ process.id, process.pid, process.created_at ]
      earlier = previous[identity]
      if earlier && earlier[:snapshot] == snapshot && earlier[:at] > OBSERVATION_TTL.ago
        return restart(process) if earlier[:at] <= OBSERVATION_INTERVAL.ago

        observed[identity] = earlier
      else
        observed[identity] = { snapshot: snapshot, at: Time.current }
      end
      nil
    end

    def stalled_snapshot(process, stalled)
      patterns = process.metadata.fetch("queues", "").split(",")
      ready = stalled.select { |queue, _| patterns.any? { |pattern| File.fnmatch?(pattern, queue) } }
      return if ready.empty?

      claims = SolidQueue::ClaimedExecution.where(process_id: process.id).order(:id).pluck(:id)
      return if claims.size >= process.metadata["pool_size"].to_i

      [ ready, claims ]
    end

    def forked_worker?(process)
      supervisor = process.supervisor
      return false unless supervisor&.kind == "Supervisor(fork)" && supervisor.hostname == process.hostname
      return false if process.pid == supervisor.pid || process.pid <= 1

      output, status = Open3.capture2("/bin/ps", "-ww", "-o", "ppid=,command=", "-p", process.pid.to_s, err: File::NULL)
      parent_pid, command = output.strip.split(/\s+/, 2)
      status.success? && parent_pid.to_i == supervisor.pid && command&.start_with?("solid-queue-worker(")
    rescue Errno::ENOENT
      false
    end

    def restart(process)
      return unless forked_worker?(process)

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
