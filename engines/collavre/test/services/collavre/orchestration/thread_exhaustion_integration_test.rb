# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class ThreadExhaustionIntegrationTest < ActiveSupport::TestCase
      # Integration test: proves that AiAgentJob's blocking nature
      # (HTTP streaming / WebSocket wait) causes cross-topic serialization
      # when Solid Queue thread pool is exhausted.
      #
      # Uses real Task + ResourceTracker + Scheduler, mocks only the
      # AI client call (which is the blocking I/O).

      THREAD_POOL_SIZE = 3 # matches production config/queue.yml

      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @agent.update!(searchable: true)

        @topics = 5.times.map do |i|
          Topic.create!(name: "Thread Test Topic #{i}", creative: @creative, user: @user)
        end

        ResourceTracker.for(@agent).reset!
      end

      teardown do
        ResourceTracker.for(@agent).reset!
      end

      test "orchestrator schedules all topics as immediate but thread pool serializes them" do
        # Part 1: Prove Scheduler marks all as :immediate
        decisions = @topics.map do |topic|
          context = build_context(topic)
          scheduler = Scheduler.new(context)
          scheduler.schedule([@agent]).first
        end

        assert decisions.all? { |d| d[:timing] == :immediate },
          "All 5 topics should be :immediate from Scheduler, " \
          "got: #{decisions.map { |d| [d[:timing], d[:reason]] }}"

        # Part 2: Simulate job execution with limited thread pool
        # Each job blocks for the duration of AI response (HTTP streaming)
        pool = Concurrent::FixedThreadPool.new(THREAD_POOL_SIZE)
        started_at = {}
        finished_at = {}
        mutex = Mutex.new
        ai_response_time = 0.3 # simulate 300ms AI response

        @topics.each_with_index do |topic, i|
          pool.post do
            mutex.synchronize { started_at[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC) }

            # Simulate AiAgentJob blocking work:
            # 1. Create task
            task = nil
            mutex.synchronize do
              task = Task.create!(
                name: "Response for topic #{i}",
                status: "running",
                trigger_event_name: "comment_created",
                agent: @agent,
                topic_id: topic.id
              )
            end

            # 2. Reserve resources
            ResourceTracker.for(@agent).reserve!("thread-test-#{i}")

            # 3. Blocking AI call (HTTP streaming wait)
            sleep(ai_response_time)

            # 4. Release resources
            ResourceTracker.for(@agent).release!("thread-test-#{i}", tokens_used: 0)
            mutex.synchronize do
              task.update!(status: "done")
              finished_at[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
        end

        pool.shutdown
        pool.wait_for_termination(10)

        # Analyze timing
        sorted_starts = started_at.sort_by { |_, t| t }

        # First 3 should start almost simultaneously
        first_batch = sorted_starts[0..2].map { |_, t| t }
        first_batch_spread = first_batch.max - first_batch.min

        # 4th and 5th should start AFTER first batch finishes
        second_batch = sorted_starts[3..4].map { |_, t| t }
        gap_to_4th = second_batch.first - first_batch.min

        assert first_batch_spread < 0.15,
          "First 3 jobs should start near-simultaneously " \
          "(spread: #{first_batch_spread.round(3)}s)"

        assert gap_to_4th >= ai_response_time * 0.8,
          "4th job should wait for a thread to free up " \
          "(gap: #{gap_to_4th.round(3)}s, expected >= #{(ai_response_time * 0.8).round(3)}s). " \
          "This proves thread pool exhaustion causes cross-topic serialization!"

        # Summary
        Rails.logger.info(
          "[ThreadExhaustionTest] With #{THREAD_POOL_SIZE} threads and 5 topics:\n" \
          "  Jobs 0-2 started within #{first_batch_spread.round(3)}s\n" \
          "  Job 3 waited #{gap_to_4th.round(3)}s (thread pool exhaustion)\n" \
          "  Total time: #{(finished_at.values.max - started_at.values.min).round(3)}s\n" \
          "  Ideal (5 threads): #{ai_response_time}s\n" \
          "  Actual (3 threads): ~#{(ai_response_time * 2).round(1)}s"
        )
      end

      test "with more threads all topics run truly in parallel" do
        pool = Concurrent::FixedThreadPool.new(5) # enough for all topics
        started_at = {}
        mutex = Mutex.new
        ai_response_time = 0.3

        @topics.each_with_index do |topic, i|
          pool.post do
            mutex.synchronize { started_at[i] = Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            sleep(ai_response_time)
          end
        end

        pool.shutdown
        pool.wait_for_termination(10)

        sorted_starts = started_at.sort_by { |_, t| t }
        total_spread = sorted_starts.last[1] - sorted_starts.first[1]

        assert total_spread < 0.15,
          "With 5 threads, all 5 jobs should start near-simultaneously " \
          "(spread: #{total_spread.round(3)}s). " \
          "Fix: increase threads in config/queue.yml"
      end

      private

      def build_context(topic)
        {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => topic.id },
          "chat" => { "content" => "@#{@agent.name}: test" },
          "comment" => { "content" => "@#{@agent.name}: test" }
        }
      end
    end
  end
end
