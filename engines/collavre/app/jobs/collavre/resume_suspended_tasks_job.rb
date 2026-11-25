# frozen_string_literal: true

module Collavre
  # Brings suspended turns back through Orchestration::TaskResumer.
  #
  #   task_id:  one task — the job TaskResumer.suspend! schedules for the moment
  #             a quota resets
  #   agent_id: every due task of one agent — for when the agent comes back
  #   neither:  the recurring sweep (config/recurring.yml) — resumes what is due
  #             and escalates what has waited past its TTL
  #
  # Durable because SolidQueue stores it, and idempotent because TaskResumer
  # re-checks the row under its lock: a duplicate or stale job finds the task
  # already resumed, not yet due, or gone, and does nothing.
  class ResumeSuspendedTasksJob < ApplicationJob
    queue_as :default

    def perform(agent_id: nil, task_id: nil)
      if task_id
        task = Task.find_by(id: task_id)
        Orchestration::TaskResumer.resume!(task) if task
      elsif agent_id
        Orchestration::TaskResumer.resume_for_agent!(agent_id)
      else
        Orchestration::TaskResumer.sweep!
      end
    end
  end
end
