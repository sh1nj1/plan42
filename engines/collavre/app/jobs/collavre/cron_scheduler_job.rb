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
  # each task fires at most once.
  #
  # Reschedule guard: uses SolidQueue::Job table (DB-based) to prevent
  # duplicate scheduler chains — no Rails.cache dependency for locking.
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

      cron.match?(time)
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
      SolidQueue::Job
        .where(class_name: self.class.name)
        .where(finished_at: nil)
        .exists?
    end
  end
end
