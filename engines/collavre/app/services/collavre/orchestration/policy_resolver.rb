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
    # A resolver is a snapshot for one decision: the enabled policies are read
    # once, on first use, and every answer it gives comes from that read.
    # Build a new resolver for each dispatch or job step rather than keeping
    # one around; nothing is cached across resolvers.
    #
    class PolicyResolver
      # Default configurations when no policy is set
      DEFAULTS = {
        "matching" => {
          # off | shadow | on
          #
          # Shadow mode compares workflow decisions with expression routing
          # while expression routing continues to determine participation.
          "workflow_routing" => "shadow"
        },
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
          # Fold un-started tasks for the same agent/topic/creative into one so a
          # burst of comments produces one answer instead of one per comment.
          "coalesce_pending_tasks" => true,
          # Drop a dispatch whose comment an in-flight turn has already been
          # given, instead of parking it as a waiter (see
          # Orchestration::DeliveryRecord).
          "drop_delivered_dispatches" => true,
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
          "enabled" => true,
          "task_stuck_threshold_minutes" => 30,            # Task running for > N minutes
          "queued_orphan_threshold_minutes" => 5,          # Queued waiter with no live blocker for > N minutes
          "create_system_comment" => true                  # Create system comment on escalation
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

      MODES = %w[off shadow on].freeze

      # `records` is the dispatch's DispatchRecords, when it has one, so the
      # topic the Matcher read is not read again for its primary agent.
      # `policies` is shared by #ignoring_topic_primary; callers leave it out.
      def initialize(context, ignore_topic_primary: false, records: nil, policies: nil)
        @context = context
        @ignore_topic_primary = ignore_topic_primary
        @records = records
        @policies = policies || Policies.new(context)
      end

      # The same decision without the topic's primary-agent pin, reading the
      # policies this resolver has already loaded.
      def ignoring_topic_primary
        self.class.new(@context, ignore_topic_primary: true, records: @records, policies: @policies)
      end

      def workflow_routing_mode
        mode = merge_policies("matching")["workflow_routing"].to_s
        MODES.include?(mode) ? mode : "shadow"
      end

      # Get merged arbitration config
      def arbitration_config
        @arbitration_config ||= merge_policies("arbitration")
      end

      # Get merged scheduling config for a specific agent
      def scheduling_config_for(agent)
        base = merge_policies("scheduling")

        # Layer agent-specific policies on top
        @policies.for_agent(agent.id, "scheduling").each do |policy|
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

      # Whether un-started tasks for the same agent/topic/creative are folded
      # into a single one (see Orchestration::TaskCoalescer).
      #
      # Resolved per agent, because that is the granularity of the thing being
      # switched: coalescing folds *same-agent* siblings, and a User-scoped
      # scheduling policy is how an administrator turns it off for one agent
      # without touching the others in the topic. #scheduling_config excludes
      # agent policies by construction, so asking it here silently ignored that
      # opt-out on every enqueue, promotion, start and notice path.
      #
      # There is deliberately no agent-less variant to fall back to: a second
      # door onto this question is how the two answers drift, and every caller
      # has the agent to hand. `nil` is accepted only for a dispatch with no
      # agent resolved yet, where the global answer is the only one there is.
      def coalesce_pending_tasks_for?(agent)
        config = agent ? scheduling_config_for(agent) : scheduling_config
        config["coalesce_pending_tasks"] != false
      end

      # Whether a dispatch is dropped outright when an in-flight turn has
      # already delivered its comment (see Orchestration::DeliveryRecord).
      #
      # Resolved per agent for the same reason coalescing is: delivery is a
      # same-agent question, and a User-scoped scheduling policy is how an
      # administrator turns this off for one agent without touching the others
      # in the topic.
      #
      # Only the *drop* is switched. The record itself keeps being written
      # whatever this says — it is evidence of what an agent was sent, and the
      # promotion door reads it to keep a parked waiter from replaying a
      # delivered comment. Gating the write here would make turning the switch
      # off mid-burst leave that door reading a record with a hole in it.
      def drop_delivered_dispatches_for?(agent)
        config = agent ? scheduling_config_for(agent) : scheduling_config
        config["drop_delivered_dispatches"] != false
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

      # Read primary_agent_id directly from the topics table.
      #
      # Public because the two sources of a primary agent carry different
      # strength: a topic-column assignment is exclusive, while a policy-level
      # primary_agent_id is only a preference. The Arbiter needs to tell them
      # apart even though #primary_agent_id collapses both.
      def topic_primary_agent_id
        return nil if @ignore_topic_primary

        topic_id = @context.dig("topic", "id")
        return nil unless topic_id
        return @records.find(Topic, topic_id)&.primary_agent_id if @records

        Topic.where(id: topic_id).pick(:primary_agent_id)
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
        policies = @policies.for_context(policy_type)

        # Merge each policy's config (later policies override earlier)
        policies.each do |policy|
          config = config.merge(policy.config)
        end

        config
      end

      # The enabled policies one decision reads: every context policy in a
      # single query, and each agent's policies once per type.
      class Policies
        def initialize(context)
          @context = context
          @agent_policies = {}
        end

        def for_context(policy_type)
          @by_type ||= OrchestratorPolicy.for_context_by_type(@context)
          @by_type.fetch(policy_type, [])
        end

        def for_agent(agent_id, policy_type)
          @agent_policies[[ agent_id, policy_type ]] ||=
            OrchestratorPolicy.for_agent(agent_id, policy_type: policy_type).to_a
        end
      end
    end
  end
end
