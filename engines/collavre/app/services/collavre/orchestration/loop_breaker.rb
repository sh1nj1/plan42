# frozen_string_literal: true

module Collavre
  module Orchestration
    # LoopBreaker detects and prevents infinite loops in agent orchestration.
    #
    # Detects:
    # - Ping-pong: Same two agents messaging back and forth too many times
    # - Creative retry: Too many tasks created on same creative in time window
    # - Task timeout: Single task running too long
    # - Token spike: Abnormal token usage in short time window
    #
    # Usage:
    #   breaker = LoopBreaker.new(context, policy_resolver: resolver)
    #   result = breaker.check
    #   if result.should_break?
    #     # Handle loop detection - escalate to human
    #   end
    #
    class LoopBreaker
      CACHE_PREFIX = "loop_breaker"
      CACHE_EXPIRY = 1.hour

      Result = Data.define(:should_break, :reason, :details) do
        def should_break?
          should_break
        end

        def safe?
          !should_break
        end
      end

      def initialize(context, policy_resolver: nil)
        @context = context
        @policy_resolver = policy_resolver || PolicyResolver.new(context)
        @config = @policy_resolver.loop_breaker_config
      end

      # Main entry point - checks all loop conditions
      def check
        return Result.new(should_break: false, reason: nil, details: {}) unless enabled?

        # Check each condition
        checks = [
          check_ping_pong,
          check_creative_retry,
          check_task_timeout,
          check_token_spike
        ]

        # Return first violation found
        violation = checks.find(&:should_break?)
        violation || Result.new(should_break: false, reason: nil, details: {})
      end

      # Record an interaction for ping-pong detection
      def record_interaction(from_agent_id, to_agent_id, creative_id)
        key = "#{CACHE_PREFIX}:ping_pong_history:#{creative_id}"
        interactions = Rails.cache.read(key) || []
        interactions << { at: Time.current.to_i, from: from_agent_id, to: to_agent_id }

        # Keep only recent interactions (within window)
        window_start = (Time.current - ping_pong_window).to_i
        interactions = interactions.select { |i| i[:at] >= window_start }

        Rails.cache.write(key, interactions, expires_in: CACHE_EXPIRY)
      end

      # Record a task creation for creative retry detection
      def record_task(creative_id, agent_id)
        key = creative_tasks_key(creative_id)
        tasks = Rails.cache.read(key) || []
        tasks << { at: Time.current.to_i, agent_id: agent_id }

        # Keep only tasks within window
        window_start = (Time.current - creative_retry_window).to_i
        tasks = tasks.select { |t| t[:at] >= window_start }

        Rails.cache.write(key, tasks, expires_in: CACHE_EXPIRY)
      end

      # Record token usage for spike detection
      def record_tokens(agent_id, tokens_used)
        key = token_usage_key(agent_id)
        usage = Rails.cache.read(key) || []
        usage << { at: Time.current.to_i, tokens: tokens_used }

        # Keep only usage within window
        window_start = (Time.current - token_spike_window).to_i
        usage = usage.select { |u| u[:at] >= window_start }

        Rails.cache.write(key, usage, expires_in: CACHE_EXPIRY)
      end

      # Reset tracking for a creative (after human intervention)
      def reset_for_creative(creative_id)
        # Clear all related cache keys
        Rails.cache.delete_matched("#{CACHE_PREFIX}:creative:#{creative_id}:*")
        Rails.cache.delete_matched("#{CACHE_PREFIX}:ping_pong:*:#{creative_id}")
      end

      private

      def enabled?
        @config["enabled"] == true
      end

      # Detect ping-pong between agents
      def check_ping_pong
        creative_id = @context.dig("creative", "id")
        return safe_result unless creative_id

        # Check the ping-pong tracking key for this creative
        key = "#{CACHE_PREFIX}:ping_pong_history:#{creative_id}"
        interactions = Rails.cache.read(key) || []

        # Count exchanges for each agent pair
        pair_exchanges = count_pair_exchanges(interactions)

        pair_exchanges.each do |pair, count|
          if count >= ping_pong_threshold
            return Result.new(
              should_break: true,
              reason: :ping_pong,
              details: {
                agents: pair,
                creative_id: creative_id,
                exchange_count: count,
                threshold: ping_pong_threshold
              }
            )
          end
        end

        safe_result
      end

      # Detect too many tasks on same creative
      def check_creative_retry
        creative_id = @context.dig("creative", "id")
        return safe_result unless creative_id

        key = creative_tasks_key(creative_id)
        tasks = Rails.cache.read(key) || []

        # Filter to window
        window_start = (Time.current - creative_retry_window).to_i
        recent_tasks = tasks.select { |t| t[:at] >= window_start }

        if recent_tasks.size >= creative_retry_threshold
          return Result.new(
            should_break: true,
            reason: :creative_retry_exceeded,
            details: {
              creative_id: creative_id,
              task_count: recent_tasks.size,
              threshold: creative_retry_threshold,
              window_minutes: @config["creative_retry_window_minutes"]
            }
          )
        end

        safe_result
      end

      # Detect tasks running too long
      def check_task_timeout
        # Find running tasks for this context (using topic_id as Task doesn't have creative_id)
        topic_id = @context.dig("topic", "id")

        return safe_result unless topic_id

        timeout_threshold = task_timeout_minutes.minutes.ago

        timed_out_task = Task.where(status: "running", topic_id: topic_id)
                              .where("created_at < ?", timeout_threshold)
                              .first

        if timed_out_task
          return Result.new(
            should_break: true,
            reason: :task_timeout,
            details: {
              task_id: timed_out_task.id,
              agent_id: timed_out_task.agent_id,
              started_at: timed_out_task.created_at,
              timeout_minutes: task_timeout_minutes
            }
          )
        end

        safe_result
      end

      # Detect token usage spikes
      def check_token_spike
        # Check for current agent or all agents in creative
        agent_id = @context.dig("agent", "id") || @context.dig("user", "id")
        return safe_result unless agent_id

        key = token_usage_key(agent_id)
        usage = Rails.cache.read(key) || []

        # Sum tokens in window
        window_start = (Time.current - token_spike_window).to_i
        recent_usage = usage.select { |u| u[:at] >= window_start }
        total_tokens = recent_usage.sum { |u| u[:tokens] }

        if total_tokens >= token_spike_threshold
          return Result.new(
            should_break: true,
            reason: :token_spike,
            details: {
              agent_id: agent_id,
              tokens_used: total_tokens,
              threshold: token_spike_threshold,
              window_minutes: @config["token_spike_window_minutes"]
            }
          )
        end

        safe_result
      end

      # Count exchanges for each pair of agents
      def count_pair_exchanges(interactions)
        return {} if interactions.size < 2

        pair_counts = Hash.new(0)
        sorted = interactions.sort_by { |i| i[:at] }

        sorted.each_cons(2) do |prev, curr|
          # Count as exchange if direction reversed (A→B then B→A)
          if prev[:from] == curr[:to] && prev[:to] == curr[:from]
            # Normalize pair key (smaller id first)
            pair = [ prev[:from], prev[:to] ].sort
            pair_counts[pair] += 1
          end
        end

        pair_counts
      end

      def safe_result
        Result.new(should_break: false, reason: nil, details: {})
      end

      # Cache keys
      def ping_pong_key(agent1_id, agent2_id, creative_id)
        # Normalize key so A-B and B-A use same key
        sorted = [ agent1_id, agent2_id ].sort
        "#{CACHE_PREFIX}:ping_pong:#{sorted[0]}-#{sorted[1]}:#{creative_id}"
      end

      def creative_tasks_key(creative_id)
        "#{CACHE_PREFIX}:creative:#{creative_id}:tasks"
      end

      def token_usage_key(agent_id)
        "#{CACHE_PREFIX}:agent:#{agent_id}:tokens:#{Date.current}"
      end

      # Config accessors
      def ping_pong_threshold
        @config["ping_pong_threshold"] || 5
      end

      def ping_pong_window
        30.minutes # Fixed window for ping-pong detection
      end

      def creative_retry_threshold
        @config["creative_retry_threshold"] || 10
      end

      def creative_retry_window
        (@config["creative_retry_window_minutes"] || 30).minutes
      end

      def task_timeout_minutes
        @config["task_timeout_minutes"] || 60
      end

      def token_spike_threshold
        @config["token_spike_threshold"] || 50_000
      end

      def token_spike_window
        (@config["token_spike_window_minutes"] || 10).minutes
      end
    end
  end
end
