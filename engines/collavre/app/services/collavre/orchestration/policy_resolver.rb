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
          "backoff_strategy" => "exponential",
          "topic_max_concurrent_jobs" => 1,
          # Loop breaker settings
          "loop_breaker_enabled" => true,
          "ping_pong_threshold" => 5,           # Max back-and-forth between same agents
          "creative_retry_threshold" => 10,     # Max tasks on same creative in time window
          "creative_retry_window_minutes" => 30,
          "task_timeout_minutes" => 60,         # Max time for a single task
          "token_spike_threshold" => 50_000,    # Token usage spike in window
          "token_spike_window_minutes" => 10
        },
        "stuck_detection" => {
          "enabled" => false,
          "task_stuck_threshold_minutes" => 30,       # Task running for > N minutes
          "creative_stall_threshold_minutes" => 120,  # Creative no progress for > N minutes
          "create_system_comment" => true             # Create system comment on escalation
        },
        "collaboration" => {
          "a2a_focus_instruction" => nil,         # nil = locale default
          "a2a_completion_instruction" => nil,
          "a2a_followup_instruction" => nil,
          "mention_rule" => nil,
          "confidence_rule" => nil,
          "escalation_rule" => nil,
          "review_rule" => nil
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

      # Get merged scheduling config (without agent-specific overrides)
      def scheduling_config
        @scheduling_config ||= merge_policies("scheduling")
      end

      # Topic-level concurrency limit
      def topic_max_concurrent_jobs
        scheduling_config["topic_max_concurrent_jobs"]
      end

      # Convenience methods
      def arbitration_strategy
        return "primary_first" if topic_primary_agent_id.present?

        arbitration_config["strategy"]
      end

      def max_responders
        arbitration_config["max_responders"]
      end

      def primary_agent_id
        topic_primary_agent_id || arbitration_config["primary_agent_id"]
      end

      # Bid strategy specific
      def confidence_threshold
        arbitration_config["confidence_threshold"]
      end

      def bid_fallback_enabled?
        arbitration_config["bid_fallback_enabled"] != false
      end

      # Loop breaker settings
      def loop_breaker_enabled?
        scheduling_config["loop_breaker_enabled"] == true
      end

      def loop_breaker_config
        {
          "enabled" => scheduling_config["loop_breaker_enabled"],
          "ping_pong_threshold" => scheduling_config["ping_pong_threshold"],
          "creative_retry_threshold" => scheduling_config["creative_retry_threshold"],
          "creative_retry_window_minutes" => scheduling_config["creative_retry_window_minutes"],
          "task_timeout_minutes" => scheduling_config["task_timeout_minutes"],
          "token_spike_threshold" => scheduling_config["token_spike_threshold"],
          "token_spike_window_minutes" => scheduling_config["token_spike_window_minutes"]
        }
      end

      # Collaboration config
      def collaboration_config
        @collaboration_config ||= merge_policies("collaboration")
      end

      # Stuck detection settings
      def stuck_detection_enabled?
        stuck_detection_config["enabled"] == true
      end

      def stuck_detection_config
        @stuck_detection_config ||= resolve("stuck_detection")
      end

      # Generic resolve method for any policy type
      def resolve(policy_type)
        merge_policies(policy_type)
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

      # Read primary_agent_id directly from the topics table
      def topic_primary_agent_id
        topic_id = @context.dig("topic", "id")
        return nil unless topic_id

        Topic.where(id: topic_id).pick(:primary_agent_id)
      end
    end
  end
end
