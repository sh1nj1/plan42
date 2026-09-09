# frozen_string_literal: true

module Collavre
  module Orchestration
    # Resolves the exact responders for an event without scheduling work.
    class Selection
      attr_reader :agents

      def initialize(context, policy_resolver:, candidate_overrides: {})
        @context = context
        @policy_resolver = policy_resolver
        @candidate_overrides = candidate_overrides
      end

      def call
        candidates = candidates_for_contexts
        @agents = [] if candidates.empty?
        return self if candidates.empty?

        @arbiter = Arbiter.new(@context, policy_resolver: @policy_resolver)
        @agents = @arbiter.select(candidates, commit: false)
        self
      end

      def commit!
        @arbiter&.commit_selection!
        self
      end

      private

      def candidates_for_contexts
        candidates = Matcher.new(@context).match
        @candidate_overrides.each do |agent_id, override|
          candidates = candidates.reject { |agent| agent.id == agent_id }
          overridden = Matcher.new(@context.deep_merge(override.deep_stringify_keys)).match
          candidates.concat(overridden.select { |agent| agent.id == agent_id })
        end
        candidates.uniq(&:id).sort_by(&:id)
      end
    end
  end
end
