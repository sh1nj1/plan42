# frozen_string_literal: true

module Collavre
  # CronSchedulerJob is a self-scheduling job that runs every minute and
  # picks up dynamically-created recurring tasks (static: false) whose
  # cron schedule matches the current minute. For each match it enqueues
  # the target job (e.g. CronActionJob).
  #
  # This exists because Solid Queue's built-in Scheduler only processes
  # static (config-defined) recurring tasks — dynamic ones created via
  # cron_create are ignored by the Scheduler.
  #
  # Self-scheduling: after each run, the job re-enqueues itself with
  # `wait: 1.minute`. Boot-time scheduling is handled by the engine
  # initializer (see collavre/engine.rb).
  #
  # Duplicate-execution guard: uses Rails.cache with a per-task, per-minute
  # key so that even if this job runs twice in the same minute window,
  # each task fires at most once. (This cache is process-local and acceptable
  # since CronSchedulerJob runs in a single SQ worker process.)
  #
  # Reschedule guard: uses SolidQueue::Job table (DB-based) to prevent
  # duplicate scheduler chains — works across all environments without
  # shared cache infrastructure.
  class CronSchedulerJob < ApplicationJob
    queue_as :default

    def perform
      now = Time.current
      dynamic_tasks = SolidQueue::RecurringTask.where(static: false)

      dynamic_tasks.find_each do |task|
        next unless schedule_matches?(task, now)
        next if already_dispatched?(task, now)

        enqueue_task(task)
        mark_dispatched(task, now)
      end
    ensure
      reschedule
    end

    private

    def schedule_matches?(task, time)
      cron = Fugit.parse(task.schedule)
      return false unless cron.is_a?(Fugit::Cron)

      # Truncate to the beginning of the current minute so that
      # cron.match? works regardless of which second the job runs at.
      minute_start = time.change(sec: 0)
      cron.match?(minute_start)
    end

    def cache_key(task, time)
      minute = time.strftime("%Y%m%d%H%M")
      "cron_scheduler:#{task.key}:#{minute}"
    end

    def already_dispatched?(task, time)
      Rails.cache.read(cache_key(task, time)).present?
    end

    def mark_dispatched(task, time)
      Rails.cache.write(cache_key(task, time), true, expires_in: 2.minutes)
    end

    def enqueue_task(task)
      job_class = task.class_name.safe_constantize
      unless job_class
        Rails.logger.warn("[CronScheduler] Unknown job class: #{task.class_name} for task #{task.key}")
        return
      end

      args = task.arguments || []
      if args.is_a?(Array) && args.first.is_a?(Hash)
        job_class.perform_later(**args.first.symbolize_keys)
      elsif args.is_a?(Array)
        job_class.perform_later(*args)
      else
        job_class.perform_later
      end

      Rails.logger.info("[CronScheduler] Enqueued #{task.class_name} for task #{task.key}")
    rescue StandardError => e
      Rails.logger.error("[CronScheduler] Failed to enqueue #{task.key}: #{e.message}")
    end

    def reschedule
      # DB-based guard: skip if a CronSchedulerJob is already pending
      return if pending_scheduler_exists?

      self.class.set(wait: 1.minute).perform_later
      Rails.logger.info("[CronScheduler] Rescheduled for next minute")
    end

    def pending_scheduler_exists?
      scope = SolidQueue::Job
        .where(class_name: self.class.name)
        .where(finished_at: nil)

      # Exclude the currently running job to avoid blocking our own reschedule
      scope = scope.where.not(id: provider_job_id) if provider_job_id.present?

      # Exclude failed jobs — they won't run again without manual retry
      failed_job_ids = SolidQueue::FailedExecution.pluck(:job_id)
      scope = scope.where.not(id: failed_job_ids) if failed_job_ids.any?

      scope.exists?
    end
  end
end
