# frozen_string_literal: true

module Collavre
  module Orchestration
    # ResourceTracker tracks per-agent resource usage for scheduling decisions.
    #
    # Tracks:
    # - Active jobs count (concurrency)
    # - Daily token usage (quota)
    # - Request rate (rate limiting)
    #
    # Uses Rails.cache by default (memory-based).
    # Can be extended to use Redis for multi-server deployments.
    #
    # Usage:
    #   tracker = ResourceTracker.for(agent)
    #   tracker.active_jobs          # => 2
    #   tracker.can_accept_work?     # => true/false
    #   tracker.reserve!(job_id)
    #   tracker.release!(job_id, tokens_used: 1500)
    #
    class ResourceTracker
      CACHE_EXPIRY_ACTIVE_JOBS = 1.hour
      CACHE_EXPIRY_TOKENS = 2.days
      CACHE_EXPIRY_RATE = 2.minutes

      class << self
        def for(agent)
          new(agent)
        end
      end

      def initialize(agent)
        @agent = agent
        @key_prefix = "orchestrator:agent:#{agent.id}"
      end

      # Current number of active jobs for this agent
      def active_jobs
        active_job_set.size
      end

      # Total tokens used today
      def tokens_today
        cache_read(tokens_today_key) || 0
      end

      # Requests in the current minute window
      def requests_this_minute
        cache_read(rate_limit_key) || 0
      end

      # Check if rate limited (exceeds requests per minute)
      def rate_limited?(limit)
        requests_this_minute >= limit
      end

      # Reserve resources for a job (call before starting work)
      def reserve!(job_id)
        jobs = active_job_set
        jobs.add(job_id.to_s)
        cache_write(active_jobs_key, jobs, expires_in: CACHE_EXPIRY_ACTIVE_JOBS)

        # Increment rate counter
        increment_rate_counter

        true
      end

      # Release resources after job completion
      def release!(job_id, tokens_used: 0)
        # Remove from active jobs
        jobs = active_job_set
        jobs.delete(job_id.to_s)
        cache_write(active_jobs_key, jobs, expires_in: CACHE_EXPIRY_ACTIVE_JOBS)

        # Add to daily token usage
        if tokens_used.positive?
          current_tokens = tokens_today
          cache_write(tokens_today_key, current_tokens + tokens_used, expires_in: CACHE_EXPIRY_TOKENS)
        end

        true
      end

      # Get current resource status
      def status
        {
          active_jobs: active_jobs,
          tokens_today: tokens_today,
          requests_this_minute: requests_this_minute
        }
      end

      # Reset all tracking (useful for testing)
      def reset!
        Rails.cache.delete(active_jobs_key)
        Rails.cache.delete(tokens_today_key)
        Rails.cache.delete(rate_limit_key)
      end

      private

      def active_job_set
        cache_read(active_jobs_key) || Set.new
      end

      def increment_rate_counter
        current = requests_this_minute
        cache_write(rate_limit_key, current + 1, expires_in: CACHE_EXPIRY_RATE)
      end

      def active_jobs_key
        "#{@key_prefix}:active_jobs"
      end

      def tokens_today_key
        "#{@key_prefix}:tokens:#{Date.current}"
      end

      def rate_limit_key
        # Window by minute
        "#{@key_prefix}:rate:#{Time.current.to_i / 60}"
      end

      def cache_read(key)
        Rails.cache.read(key)
      end

      def cache_write(key, value, expires_in:)
        Rails.cache.write(key, value, expires_in: expires_in)
      end
    end
  end
end
