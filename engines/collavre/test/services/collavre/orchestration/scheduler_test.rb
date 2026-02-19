# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class SchedulerTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @agent = users(:ai_bot)
        @agent.update!(searchable: true)
        @topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        @context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        }

        # Reset resource tracking
        ResourceTracker.for(@agent).reset!
      end

      teardown do
        ResourceTracker.for(@agent).reset!
      end

      # Immediate scheduling (default)
      test "schedules immediately when no constraints" do
        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal 1, decisions.size
        assert_equal :immediate, decisions.first[:timing]
        assert_equal @agent, decisions.first[:agent]
      end

      # Concurrency limit
      test "delays when at concurrency limit" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "max_concurrent_jobs" => 2 }
        )

        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("job-1")
        tracker.reserve!("job-2")

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal 1, decisions.size
        assert_equal :delayed, decisions.first[:timing]
        assert_equal :busy, decisions.first[:reason]
        assert decisions.first[:delay].present?
      end

      test "schedules immediately when under concurrency limit" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "max_concurrent_jobs" => 3 }
        )

        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("job-1")
        tracker.reserve!("job-2")

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :immediate, decisions.first[:timing]
      end

      # Daily token quota
      test "rejects when daily quota exceeded" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "daily_token_limit" => 1000 }
        )

        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("job-1")
        tracker.release!("job-1", tokens_used: 1500)

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :rejected, decisions.first[:timing]
        assert_equal :quota_exceeded, decisions.first[:reason]
      end

      test "schedules when under daily quota" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "daily_token_limit" => 10_000 }
        )

        tracker = ResourceTracker.for(@agent)
        tracker.reserve!("job-1")
        tracker.release!("job-1", tokens_used: 5000)

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :immediate, decisions.first[:timing]
      end

      # Rate limiting
      test "delays when rate limited" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "rate_limit_per_minute" => 3 }
        )

        tracker = ResourceTracker.for(@agent)
        3.times { |i| tracker.reserve!("job-#{i}") }

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :delayed, decisions.first[:timing]
        assert_equal :rate_limited, decisions.first[:reason]
      end

      # Multiple agents
      test "schedules multiple agents independently" do
        agent2 = User.create!(
          name: "Agent 2",
          email: "agent2_sched_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true
        )

        # agent1 is over quota
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "daily_token_limit" => 100 }
        )
        ResourceTracker.for(@agent).reserve!("j1")
        ResourceTracker.for(@agent).release!("j1", tokens_used: 200)

        # agent2 has no constraints
        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent, agent2 ])

        assert_equal 2, decisions.size
        assert_equal :rejected, decisions.find { |d| d[:agent] == @agent }[:timing]
        assert_equal :immediate, decisions.find { |d| d[:agent] == agent2 }[:timing]
      ensure
        ResourceTracker.for(@agent).reset!
        ResourceTracker.for(agent2).reset! if agent2
      end

      # Backoff strategies
      test "uses exponential delay by default" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: { "max_concurrent_jobs" => 0 }
        )

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        # Default backoff_strategy is "exponential" (base * 2)
        assert_equal Scheduler::BACKOFF_DELAYS[:exponential_base] * 2, decisions.first[:delay]
      end

      test "uses linear delay when configured" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: {
            "max_concurrent_jobs" => 0,
            "backoff_strategy" => "linear"
          }
        )

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal Scheduler::BACKOFF_DELAYS[:linear], decisions.first[:delay]
      end

      test "uses configured backoff strategy" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @agent.id,
          config: {
            "max_concurrent_jobs" => 0,
            "backoff_strategy" => "immediate"
          }
        )

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal 0, decisions.first[:delay]
      end

      # Topic concurrency
      test "defers when topic running count meets limit" do
        Task.create!(
          name: "Running task",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: @topic.id
        )

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal 1, decisions.size
        assert_equal :deferred, decisions.first[:timing]
        assert_equal @agent, decisions.first[:agent]
      end

      test "schedules immediately when topic running count is under limit" do
        # No running tasks for this topic → 0 < 1 → immediate
        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :immediate, decisions.first[:timing]
      end

      test "defers based on configured topic_max_concurrent_jobs" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          config: { "topic_max_concurrent_jobs" => 2 }
        )

        Task.create!(name: "t1", status: "running", trigger_event_name: "e", agent: @agent, topic_id: @topic.id)
        Task.create!(name: "t2", status: "running", trigger_event_name: "e", agent: @agent, topic_id: @topic.id)

        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :deferred, decisions.first[:timing]
      end

      test "does not defer when topic key is absent from context" do
        context_without_topic = { "creative" => { "id" => @creative.id } }

        scheduler = Scheduler.new(context_without_topic)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :immediate, decisions.first[:timing]
      end

      test "defers on main topic when topic_id is nil and running task exists" do
        main_topic_context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => nil }
        }

        Task.create!(
          name: "Running main-topic task",
          status: "running",
          trigger_event_name: "comment_created",
          agent: @agent,
          topic_id: nil
        )

        scheduler = Scheduler.new(main_topic_context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal 1, decisions.size
        assert_equal :deferred, decisions.first[:timing]
      end

      test "schedules immediately on main topic when no running task" do
        main_topic_context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => nil }
        }

        scheduler = Scheduler.new(main_topic_context)
        decisions = scheduler.schedule([ @agent ])

        assert_equal :immediate, decisions.first[:timing]
      end

      test "defers second agent in same batch when topic limit is 1" do
        agent2 = User.create!(
          name: "Agent Batch2",
          email: "agent_batch2_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true
        )

        # No running tasks — but scheduling two agents in one batch
        scheduler = Scheduler.new(@context)
        decisions = scheduler.schedule([ @agent, agent2 ])

        assert_equal 2, decisions.size
        assert_equal :immediate, decisions.first[:timing]
        assert_equal :deferred, decisions.last[:timing]
      ensure
        ResourceTracker.for(agent2).reset! if agent2
      end

      # Default policy values
      test "uses default limits when no policy exists" do
        scheduler = Scheduler.new(@context)

        # Should use default max_concurrent_jobs (5)
        tracker = ResourceTracker.for(@agent)
        4.times { |i| tracker.reserve!("job-#{i}") }

        decisions = scheduler.schedule([ @agent ])
        assert_equal :immediate, decisions.first[:timing]

        tracker.reserve!("job-5")
        decisions = scheduler.schedule([ @agent ])
        assert_equal :delayed, decisions.first[:timing]
      end
    end
  end
end

# Temporarily appended test - cross-topic parallelism
