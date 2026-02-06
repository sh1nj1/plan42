# frozen_string_literal: true

module Collavre
  module Orchestration
    # PolicyResolver finds and merges applicable policies for a given context.
    #
    # Policy precedence (later overrides earlier):
    # 1. Global policies
    # 2. Creative-level policies
    # 3. Topic-level policies
    # 4. Agent-level policies (for scheduling)
    #
    # Usage:
    #   resolver = PolicyResolver.new(context)
    #   resolver.arbitration_config
    #   # => { "strategy" => "primary_first", "max_responders" => 1 }
    #
    class PolicyResolver
      # Default configurations when no policy is set
      DEFAULTS = {
        "arbitration" => {
          "strategy" => "all",
          "max_responders" => nil # nil means unlimited
        },
        "scheduling" => {
          "max_concurrent_jobs" => 5,
          "daily_token_limit" => 100_000,
          "rate_limit_per_minute" => 20,
          "backoff_strategy" => "exponential"
        }
      }.freeze

      def initialize(context)
        @context = context
      end

      # Get merged arbitration config
      def arbitration_config
        @arbitration_config ||= merge_policies("arbitration")
      end

      # Get merged scheduling config for a specific agent
      def scheduling_config_for(agent)
        base = merge_policies("scheduling")

        # Layer agent-specific policies on top
        agent_policies = OrchestratorPolicy.for_agent(agent.id, policy_type: "scheduling")
        agent_policies.each do |policy|
          base = base.merge(policy.config)
        end

        base
      end

      # Convenience methods
      def arbitration_strategy
        arbitration_config["strategy"]
      end

      def max_responders
        arbitration_config["max_responders"]
      end

      def primary_agent_id
        arbitration_config["primary_agent_id"]
      end

      # Bid strategy specific
      def confidence_threshold
        arbitration_config["confidence_threshold"]
      end

      def bid_fallback_enabled?
        arbitration_config["bid_fallback_enabled"] != false
      end

      private

      def merge_policies(policy_type)
        # Start with defaults
        config = DEFAULTS[policy_type]&.dup || {}

        # Get applicable policies in priority order
        policies = OrchestratorPolicy.for_context(@context, policy_type: policy_type)

        # Merge each policy's config (later policies override earlier)
        policies.each do |policy|
          config = config.merge(policy.config)
        end

        config
      end
    end
  end
end
