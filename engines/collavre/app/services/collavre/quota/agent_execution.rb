# frozen_string_literal: true

module Collavre
  module Quota
    # Keep the provider quota boundary outside the ordinary completion path:
    # quota never becomes a successful empty answer or an AI Error reply.
    module AgentExecution
      def call
        Recovery.guard!(@task)
        @quota_execution_generation = Orchestration::ExecutionFence.generation(@task)
        super
      rescue ExceededError => error
        @streamer&.finalize
        result = Recovery.suspend!(@task, error, expected_generation: @quota_execution_generation)
        raise CancelledError unless result
        @lifecycle_manager&.broadcast_status("idle")
        raise TaskSuspendedError
      end

      private

      def execute_llm_conversation
        super.tap do
          Recovery.succeeded!(@agent) if @client.respond_to?(:last_handoff_failed?) && !@client.last_handoff_failed?
        end
      end
    end
  end
end
