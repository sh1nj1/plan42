# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class ThreadExhaustionTest < ActiveSupport::TestCase
      # Reproduces the production issue:
      # Same AI agent is mentioned in multiple topics simultaneously.
      # Scheduler correctly marks all as :immediate,
      # but Solid Queue only has 3 worker threads (config/queue.yml).
      # Since AiAgentJob blocks (HTTP streaming waits for full response),
      # 3 running jobs exhaust the thread pool → 4th+ jobs queue up.
      #
      # This test proves the bottleneck is at the job execution layer,
      # NOT the orchestration/scheduling layer.

      SIMULATED_THREADS = 3 # matches config/queue.yml threads for default queue

      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @agent.update!(searchable: true)

        @topics = 5.times.map do |i|
          Topic.create!(name: "Topic #{i}", creative: @creative, user: @user)
        end

        ResourceTracker.for(@agent).reset!
      end

      teardown do
        ResourceTracker.for(@agent).reset!
      end

      test "scheduler allows all topics to run in parallel (no bottleneck here)" do
        # Schedule 5 topics sequentially — all should be :immediate
        # because topic_max_concurrent_jobs checks per-topic, not globally
        all_immediate = @topics.all? do |topic|
          context = {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => topic.id }
          }
          scheduler = Scheduler.new(context)
          decisions = scheduler.schedule([ @agent ])
          decisions.first[:timing] == :immediate
        end

        assert all_immediate,
          "All 5 topics should be scheduled as :immediate by the Scheduler"
      end

      test "thread pool becomes the bottleneck with blocking jobs" do
        # Simulate: 3 threads occupied by blocking AI agent jobs
        started = Queue.new
        finish = Queue.new
        completed = Concurrent::AtomicFixnum.new(0)

        # Simulate thread pool with limited threads (like Solid Queue)
        pool = Concurrent::FixedThreadPool.new(SIMULATED_THREADS)

        # Submit 5 "blocking" jobs (simulating AiAgentJob with HTTP streaming)
        5.times do |i|
          pool.post do
            started.push(i)
            finish.pop # block until signaled — simulates HTTP streaming wait
            completed.increment
          end
        end

        # Wait for first 3 to start (thread pool is full)
        3.times { started.pop }

        # Give a moment for any additional threads to start
        sleep 0.1

        # Only 3 should have started — thread pool is exhausted
        assert_equal 0, started.size,
          "No more jobs should start — all #{SIMULATED_THREADS} threads are occupied"

        assert_equal 0, completed.value,
          "No jobs completed yet (all blocking)"

        # Release one thread
        finish.push(:done)
        sleep 0.1

        # Now the 4th job should start
        assert_equal 1, started.size,
          "4th job should start after one thread is freed"

        # Release all remaining
        4.times { finish.push(:done) }
        pool.shutdown
        pool.wait_for_termination(5)

        assert_equal 5, completed.value, "All 5 jobs should complete eventually"
      end

      test "increasing thread count allows more parallel jobs" do
        more_threads = 5
        pool = Concurrent::FixedThreadPool.new(more_threads)

        started = Concurrent::AtomicFixnum.new(0)
        finish = Queue.new

        5.times do
          pool.post do
            started.increment
            finish.pop
          end
        end

        sleep 0.2

        assert_equal 5, started.value,
          "With #{more_threads} threads, all 5 jobs should start immediately"

        5.times { finish.push(:done) }
        pool.shutdown
        pool.wait_for_termination(5)
      end
    end
  end
end
