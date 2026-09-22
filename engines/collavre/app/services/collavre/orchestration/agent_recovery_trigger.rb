# frozen_string_literal: true

module Collavre
  module Orchestration
    # Recheck on every positive probe so a failed enqueue heals on the next
    # sweep, including per-engine recovery while gateway rollup stays degraded.
    module AgentRecoveryTrigger
      def self.call(agent)
        return unless agent.agent_online?
        return unless Task.where(agent_id: agent.id, status: "suspended").exists?

        ResumeSuspendedTasksJob.perform_later(agent_id: agent.id)
      end
    end
  end
end
