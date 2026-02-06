# frozen_string_literal: true

module Collavre
  module Orchestration
    # Arbiter decides which agents will actually respond from the qualified candidates.
    # This implements "floor control" - preventing multiple agents from responding simultaneously.
    #
    # Strategies (to be implemented in Phase 2):
    # - all: All candidates respond (current behavior)
    # - primary_first: Primary agent responds, others only if primary unavailable
    # - round_robin: Rotate between agents
    # - bid: Agents bid based on relevance score
    #
    # For now, this is a pass-through that returns all candidates.
    #
    class Arbiter
      def initialize(context)
        @context = context
      end

      # Select which agents will respond from the candidates
      # @param candidates [Array<User>] Qualified agents from Matcher
      # @return [Array<User>] Agents that will actually respond
      def select(candidates)
        # Phase 1: Pass through all candidates (current behavior)
        # Phase 2: Implement strategies based on policies
        candidates
      end
    end
  end
end
