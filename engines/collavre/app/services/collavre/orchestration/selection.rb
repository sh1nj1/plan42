# frozen_string_literal: true

module Collavre
  module Orchestration
    # Resolves the exact responders for an event without scheduling work.
    class Selection
      def initialize(context, policy_resolver:)
        @context = context
        @policy_resolver = policy_resolver
      end

      def call
        candidates = Matcher.new(@context).match
        return [] if candidates.empty?

        Arbiter.new(@context, policy_resolver: @policy_resolver).select(candidates)
      end
    end
  end
end
