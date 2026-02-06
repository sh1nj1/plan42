# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class ResourceTrackerTest < ActiveSupport::TestCase
      setup do
        @agent = users(:ai_bot)
        @tracker = ResourceTracker.for(@agent)
        @tracker.reset!
      end

      teardown do
        @tracker.reset!
      end

      test "active_jobs starts at zero" do
        assert_equal 0, @tracker.active_jobs
      end

      test "reserve! increments active_jobs" do
        @tracker.reserve!("job-1")
        assert_equal 1, @tracker.active_jobs

        @tracker.reserve!("job-2")
        assert_equal 2, @tracker.active_jobs
      end

      test "release! decrements active_jobs" do
        @tracker.reserve!("job-1")
        @tracker.reserve!("job-2")
        assert_equal 2, @tracker.active_jobs

        @tracker.release!("job-1", tokens_used: 0)
        assert_equal 1, @tracker.active_jobs

        @tracker.release!("job-2", tokens_used: 0)
        assert_equal 0, @tracker.active_jobs
      end

      test "tokens_today starts at zero" do
        assert_equal 0, @tracker.tokens_today
      end

      test "release! accumulates tokens_used" do
        @tracker.reserve!("job-1")
        @tracker.release!("job-1", tokens_used: 1000)
        assert_equal 1000, @tracker.tokens_today

        @tracker.reserve!("job-2")
        @tracker.release!("job-2", tokens_used: 500)
        assert_equal 1500, @tracker.tokens_today
      end

      test "rate_limited? returns false when under limit" do
        assert_not @tracker.rate_limited?(10)
      end

      test "rate_limited? returns true when at or over limit" do
        5.times { |i| @tracker.reserve!("job-#{i}") }

        assert @tracker.rate_limited?(5)
        assert @tracker.rate_limited?(3)
        assert_not @tracker.rate_limited?(10)
      end

      test "requests_this_minute increments with reserve!" do
        assert_equal 0, @tracker.requests_this_minute

        @tracker.reserve!("job-1")
        assert_equal 1, @tracker.requests_this_minute

        @tracker.reserve!("job-2")
        assert_equal 2, @tracker.requests_this_minute
      end

      test "status returns current resource state" do
        @tracker.reserve!("job-1")
        @tracker.release!("job-1", tokens_used: 100)
        @tracker.reserve!("job-2")

        status = @tracker.status
        assert_equal 1, status[:active_jobs]
        assert_equal 100, status[:tokens_today]
        assert_equal 2, status[:requests_this_minute]
      end

      test "reset! clears all tracking data" do
        @tracker.reserve!("job-1")
        @tracker.release!("job-1", tokens_used: 1000)

        @tracker.reset!

        assert_equal 0, @tracker.active_jobs
        assert_equal 0, @tracker.tokens_today
        assert_equal 0, @tracker.requests_this_minute
      end

      test "duplicate job_id reserve is handled" do
        @tracker.reserve!("job-1")
        @tracker.reserve!("job-1")

        # Set semantics - same job_id only counted once
        assert_equal 1, @tracker.active_jobs
      end

      test "release! unknown job_id is safe" do
        # Should not raise error
        @tracker.release!("unknown-job", tokens_used: 0)
        assert_equal 0, @tracker.active_jobs
      end
    end
  end
end
