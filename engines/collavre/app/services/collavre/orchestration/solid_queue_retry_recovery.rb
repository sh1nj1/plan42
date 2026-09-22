# frozen_string_literal: true

module Collavre
  module Orchestration
    # Solid Queue 1.7 retries must return the interrupted turn to admission
    # before making its original job ready. Use the same failure lock as the
    # recovery sweep, so only one path can take ownership of that attempt.
    module SolidQueueRetryRecovery
      def retry
        with_lock do
          Task.transaction do
            TaskResumer.reclaim_for_retry!(job.active_job_id) if job.class_name == "Collavre::AiAgentJob"
            super
          end
        end
      end

      module Bulk
        # FailedExecution.retry_all calls this inside its transaction, after
        # lock_all_from_jobs has locked the failure rows.
        def dispatch_jobs(job_ids)
          Task.transaction do
            SolidQueue::Job.where(id: job_ids, class_name: "Collavre::AiAgentJob").find_each do |job|
              TaskResumer.reclaim_for_retry!(job.active_job_id)
            end
            super
          end
        end
      end
    end
  end
end
