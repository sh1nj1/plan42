# frozen_string_literal: true

module Collavre
  module Orchestration
    # Scheduler decides when to execute agent jobs based on resource availability.
    #
    # Scheduling decisions:
    # - :immediate - Execute now
    # - :delayed - Execute after a delay (with :delay value)
    # - :rejected - Do not execute (with :reason)
    #
    # Resource checks (to be implemented in Phase 3):
    # - Active jobs count (concurrency limit)
    # - Daily token usage (quota)
    # - Rate limiting (requests per minute)
    #
    # For now, this schedules all agents immediately.
    #
    class Scheduler
      def initialize(context)
        @context = context
      end

      # Schedule agents for execution
      # @param agents [Array<User>] Agents selected by Arbiter
      # @return [Array<Hash>] Scheduling decisions
      #   Each decision: { agent:, timing:, delay: (optional), reason: (optional) }
      def schedule(agents)
        # Phase 1: Immediate execution for all (current behavior)
        # Phase 3: Check resources and apply policies
        agents.map do |agent|
          {
            agent: agent,
            timing: :immediate
          }
        end
      end
    end
  end
end
