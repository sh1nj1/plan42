# frozen_string_literal: true

module Collavre
  # Solid Queue, not application boot time, decides whether an execution owner
  # died. A failed process execution is durable even after its claim is removed.
  class RecoverInterruptedTasksJob < ApplicationJob
    queue_as :default

    OWNER_FAILURES = %w[
      SolidQueue::Processes::ProcessExitError
      SolidQueue::Processes::ProcessPrunedError
      SolidQueue::Processes::ProcessMissingError
      SolidQueue::Processes::ThreadTerminatedError
    ].freeze

    def perform
      return unless defined?(SolidQueue::Job)

      Task.where(status: %w[pending running delegated]).find_each do |task|
        recover(task)
      end
    end

    private

    def recoverable_execution?(task)
      return true if task.running?
      return false unless task.delegated? && task.agent.claude_channel_agent?

      generation = Orchestration::ExecutionFence.generation(task)
      handoff = task.trigger_event_payload[Orchestration::ExecutionFence::HANDOFF_KEY]
      generation.present? && handoff == { "generation" => generation, "state" => Orchestration::ExecutionFence::HANDOFF_PENDING }
    end

    # Reclaim commits to the primary database before retry commits to the queue.
    # Pending + retained job id + retired generation is the durable retry intent.
    # If queue commit failed, retry the same job; never enqueue a replacement.
    def retry_reclaimed(task, failure)
      return if Orchestration::ExecutionFence.generation(task).present?

      failure.retry
    end

    def recover(task)
      execution_job_id = task.trigger_event_payload&.fetch("execution_job_id", nil)
      return if execution_job_id.blank?

      job = SolidQueue::Job.find_by(active_job_id: execution_job_id, class_name: "Collavre::AiAgentJob")
      failure = job&.failed_execution
      return unless failure

      outcome = failure.with_lock do
        # Never infer death from task age or absence of a claim. Ready, blocked,
        # scheduled and still-claimed jobs may run on another healthy worker.
        next if SolidQueue::ClaimedExecution.exists?(job_id: job.id)

        task.with_lock do
          next unless task.trigger_event_payload["execution_job_id"] == execution_job_id
          next retry_reclaimed(task, failure) if task.pending?
          next unless OWNER_FAILURES.include?(failure.exception_class) && recoverable_execution?(task)
          Orchestration::TaskResumer.suspend!(task, reason: "server_restart").tap do |result|
            # Queue and Task can use separate databases. Commit a permanent
            # execution fence with suspension even if queue retirement rolls back.
            if result
              RetiredTaskExecution.create_or_find_by!(execution_job_id: execution_job_id)
              failure.discard
            end
          end
        end
      end
      Orchestration::TaskResumer.resume!(task.reload) if outcome == :suspended
    rescue ActiveRecord::RecordNotFound
      # A concurrent retry/discard removed the failure; its new owner wins.
      nil
    end
  end
end
