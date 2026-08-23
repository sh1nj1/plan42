# frozen_string_literal: true

module Collavre
  module Orchestration
    # Resolves the exact responders for an event without scheduling work.
    class Selection
      attr_reader :agents

      def initialize(context, policy_resolver:)
        @context = context
        @policy_resolver = policy_resolver
      end

      def call
        candidates = Matcher.new(@context).match
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
    end
  end
end
