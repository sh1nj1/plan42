# frozen_string_literal: true

module Collavre
  module Orchestration
    # Solid Queue 1.7 retries must return the interrupted turn to admission
    # before making its original job ready. Use the same failure lock as the
    # recovery sweep, so only one path can take ownership of that attempt.
    module SolidQueueRetryRecovery
      RETRY_FAILURE_KEY = "retry_failure_id"

      def self.reclaim(job, failure_id)
        tasks = TaskResumer.reclaim_for_retry!(job.active_job_id)
        tasks << TaskResumer.reclaimed_task(job.active_job_id)
        tasks.compact.uniq.each do |task|
          task.with_lock do
            next unless task.pending? && task.trigger_event_payload["execution_job_id"] == job.active_job_id
            next if ExecutionFence.generation(task).present?

            task.update!(trigger_event_payload: task.trigger_event_payload.merge(RETRY_FAILURE_KEY => failure_id))
          end
        end
      end

      def retry
        with_lock do
          return discard if job.class_name == "Collavre::AiAgentJob" && RetiredTaskExecution.exists?(execution_job_id: job.active_job_id)

          Task.transaction do
            SolidQueueRetryRecovery.reclaim(job, id) if job.class_name == "Collavre::AiAgentJob"
            super
          end
        end
      end

      module Bulk
        # FailedExecution.retry_all calls this inside its transaction, after
        # lock_all_from_jobs has locked the failure rows.
        def dispatch_jobs(job_ids)
          candidates = SolidQueue::Job.where(id: job_ids, class_name: "Collavre::AiAgentJob").pluck(:id, :active_job_id)
          retired_ids = RetiredTaskExecution.where(execution_job_id: candidates.map(&:last)).pluck(:execution_job_id)
          retired = candidates.filter_map { |id, active_id| id if retired_ids.include?(active_id) }
          discard_all_from_jobs(SolidQueue::Job.where(id: retired)) if retired.any?
          job_ids -= retired
          Task.transaction do
            SolidQueue::Job.where(id: job_ids, class_name: "Collavre::AiAgentJob").find_each do |job|
              SolidQueueRetryRecovery.reclaim(job, job.failed_execution.id)
            end
            super(job_ids)
          end
        end
      end
    end
  end
end
