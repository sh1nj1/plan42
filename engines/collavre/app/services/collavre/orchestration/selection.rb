# frozen_string_literal: true

module Collavre
  module Orchestration
    # Resolves the exact responders for an event without scheduling work.
    class Selection
      attr_reader :agents, :workflow_rule, :workflow_snapshot

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
        matcher = Matcher.new(@context)
        base = matcher.match
        @workflow_rule = matcher.workflow_rule
        @workflow_snapshot = matcher.workflow_snapshot
        candidates = base
        @candidate_overrides.each do |agent_id, override|
          candidates = candidates.reject { |agent| agent.id == agent_id }
          candidates.concat(overridden_candidates(override).select { |agent| agent.id == agent_id })
        end
        restore_match_order(candidates.uniq(&:id), base)
      end

      def overridden_candidates(override)
        matcher = Matcher.new(@context.deep_merge(override.deep_stringify_keys))
        candidates = matcher.match
        # A sender override can change Liquid's winning rule. Only candidates
        # from the base decision may share its execution (or ordinary route).
        # Compare the snapshot too, so an intervening rule edit fails closed.
        return [] unless matcher.workflow_rule == @workflow_rule && matcher.workflow_snapshot == @workflow_snapshot

        candidates
      end

      # The Matcher's order is the floor order: Scheduler#schedule walks the
      # array and, under topic_max_concurrent_jobs, admits whom it reaches
      # first. For mentions that order is the order the names were written, so
      # sorting by id here would let "@second: your turn" answer ahead of
      # "@first:" purely for having the smaller id.
      #
      # Rebuilding an override's candidate appends it, so restore each agent to
      # its position in the unoverridden match. An agent the base match did not
      # produce has no such position and sorts last, by id for determinism —
      # every Matcher path already returns a stable order (mention order, or
      # `order(:id)` for expression routing), so nothing else needs sorting.
      def restore_match_order(candidates, base)
        base_order = base.each_with_index.to_h { |agent, index| [ agent.id, index ] }
        candidates.sort_by { |agent| [ base_order[agent.id] || base_order.size, agent.id ] }
      end
    end
  end
end
