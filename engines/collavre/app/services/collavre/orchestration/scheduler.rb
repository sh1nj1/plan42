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
    # Resource checks:
    # - Active jobs count (concurrency limit)
    # - Daily token usage (quota)
    # - Rate limiting (requests per minute)
    #
    class Scheduler
      # Default backoff delays
      BACKOFF_DELAYS = {
        immediate: 0,
        linear: 30.seconds,
        exponential_base: 10.seconds
      }.freeze

      def initialize(context, policy_resolver: nil)
        @context = context
        @policy_resolver = policy_resolver || PolicyResolver.new(context)
      end

      # Schedule agents for execution
      # @param agents [Array<User>] Agents selected by Arbiter
      # @return [Array<Hash>] Scheduling decisions
      #   Each decision: { agent:, timing:, delay: (optional), reason: (optional) }
      def schedule(agents)
        agents.map do |agent|
          evaluate(agent)
        end
      end

      private

      def evaluate(agent)
        tracker = ResourceTracker.for(agent)
        config = @policy_resolver.scheduling_config_for(agent)

        # Check 1: Concurrency limit
        max_concurrent = config["max_concurrent_jobs"] || 5
        if tracker.active_jobs >= max_concurrent
          return delayed_decision(agent, :busy, config)
        end

        # Check 2: Daily token quota
        daily_limit = config["daily_token_limit"]
        if daily_limit && tracker.tokens_today >= daily_limit
          return rejected_decision(agent, :quota_exceeded)
        end

        # Check 3: Rate limit
        rate_limit = config["rate_limit_per_minute"]
        if rate_limit && tracker.rate_limited?(rate_limit)
          return delayed_decision(agent, :rate_limited, config)
        end

        # All checks passed - immediate execution
        immediate_decision(agent)
      end

      def immediate_decision(agent)
        {
          agent: agent,
          timing: :immediate
        }
      end

      def delayed_decision(agent, reason, config)
        {
          agent: agent,
          timing: :delayed,
          delay: calculate_delay(config, reason),
          reason: reason
        }
      end

      def rejected_decision(agent, reason)
        {
          agent: agent,
          timing: :rejected,
          reason: reason
        }
      end

      def calculate_delay(config, _reason)
        strategy = config["backoff_strategy"] || "linear"

        case strategy
        when "immediate"
          BACKOFF_DELAYS[:immediate]
        when "exponential"
          # Simple exponential: base * 2^(active_jobs - max)
          # For now, use a fixed multiplier
          BACKOFF_DELAYS[:exponential_base] * 2
        else # linear
          BACKOFF_DELAYS[:linear]
        end
      end
    end
  end
end
