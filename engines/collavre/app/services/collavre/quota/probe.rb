# frozen_string_literal: true

module Collavre
  module Quota
    # The election survives process restarts and keeps other topics parked until
    # one real provider completion proves that this quota window has reopened.
    class Probe
      def self.available?(agent, task)
        agent = agent.class.find(agent.id)
        return false if Recovery.window_blocked?(agent)
        return true if agent.quota_retry_count.zero?

        task.present? && candidate_id(agent) == task.id
      end

      # Read only: TaskResumer calls this while holding a task lock. Never take
      # an agent lock here (Recovery takes agent -> task locks in that order).
      def self.candidate_id(agent)
        active = Task.where(agent_id: agent.id, status: Task::ACTIVE_STATUSES)
        return agent.quota_probe_task_id if active.exists?(id: agent.quota_probe_task_id)

        active.where(suspend_reason: "quota").order(:id).pick(:id)
      end

      # Called under the agent lock immediately before the provider handoff.
      def self.claim!(agent, task)
        return if agent.quota_retry_count.zero?

        generation = Orchestration::ExecutionFence.generation(task)
        task.with_lock do
          raise CancelledError unless task.running? || task.delegated?
          raise CancelledError unless Orchestration::ExecutionFence.current?(task, generation)

          agent.update!(quota_probe_task_id: task.id, quota_probe_generation: generation)
        end
      end

      def self.completed?(agent, task, generation)
        task.id == agent.quota_probe_task_id && agent.quota_probe_generation.present? &&
          agent.quota_probe_generation == generation
      end
    end
  end
end
