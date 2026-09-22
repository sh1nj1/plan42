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

      Task.where(status: "running").find_each do |task|
        recover(task)
      end
    end

    private

    def recover(task)
      # A channel client owns its turn across server restarts. Only the offline
      # grace/presence policy may suspend it, including its dispatch window.
      return if task.agent&.claude_channel_agent?
      execution_job_id = task.trigger_event_payload&.fetch("execution_job_id", nil)
      return if execution_job_id.blank?

      job = SolidQueue::Job.find_by(active_job_id: execution_job_id, class_name: "Collavre::AiAgentJob")
      failure = job&.failed_execution
      return unless failure

      outcome = failure.with_lock do
        next unless OWNER_FAILURES.include?(failure.exception_class)
        # Never infer death from task age or absence of a claim. Ready, blocked,
        # scheduled and still-claimed jobs may run on another healthy worker.
        next if SolidQueue::ClaimedExecution.exists?(job_id: job.id)

        task.with_lock do
          next unless task.running? && task.trigger_event_payload["execution_job_id"] == execution_job_id
          Orchestration::TaskResumer.suspend!(task, reason: "server_restart")
        end
      end
      Orchestration::TaskResumer.resume!(task.reload) if outcome == :suspended
    rescue ActiveRecord::RecordNotFound
      # A concurrent retry/discard removed the failure; its new owner wins.
      nil
    end
  end
end
