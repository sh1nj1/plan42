# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class ArbiterTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        @context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        }

        # Use existing fixture agents
        @agent1 = users(:ai_bot)
        @agent1.update!(searchable: true)

        # Create additional agents with llm_vendor to make them AI agents
        @agent2 = User.create!(
          name: "Agent 2",
          email: "agent2_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true
        )
        @agent3 = User.create!(
          name: "Agent 3",
          email: "agent3_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true
        )

        @candidates = [ @agent1, @agent2, @agent3 ]
      end

      # Strategy: all
      test "all strategy returns all candidates" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "all" }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal @candidates, selected
      end

      test "all strategy with max_responders limits results" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "all", "max_responders" => 2 }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal 2, selected.size
        assert_equal [ @agent1, @agent2 ], selected
      end

      # Strategy: primary_first
      test "primary_first returns primary agent when available" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "primary_first", "primary_agent_id" => @agent2.id }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal [ @agent2 ], selected
      end

      test "primary_first returns first candidate when primary not in candidates" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "primary_first", "primary_agent_id" => 99999 }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal [ @agent1 ], selected
      end

      test "primary_first returns first candidate when no primary configured" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "primary_first" }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal [ @agent1 ], selected
      end

      # Strategy: round_robin
      test "round_robin rotates through agents" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "round_robin" }
        )

        # Clear any existing cache
        Rails.cache.delete("orchestrator:round_robin:topic:#{@topic.id}")

        arbiter = Arbiter.new(@context)

        # First call should return first agent
        selected1 = arbiter.select(@candidates)
        assert_equal [ @agent1 ], selected1

        # Second call should return second agent
        selected2 = arbiter.select(@candidates)
        assert_equal [ @agent2 ], selected2

        # Third call should return third agent
        selected3 = arbiter.select(@candidates)
        assert_equal [ @agent3 ], selected3

        # Fourth call should wrap around to first agent
        selected4 = arbiter.select(@candidates)
        assert_equal [ @agent1 ], selected4
      end

      test "round_robin handles removed agents gracefully" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "round_robin" }
        )

        # Simulate last responder was agent2
        Rails.cache.write(
          "orchestrator:round_robin:topic:#{@topic.id}",
          @agent2.id,
          expires_in: 24.hours
        )

        # Now candidates don't include agent2
        candidates_without_agent2 = [ @agent1, @agent3 ]

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(candidates_without_agent2)

        # Should start from beginning since agent2 is not in candidates
        assert_equal [ @agent1 ], selected
      end

      # Edge cases
      test "returns empty array for empty candidates" do
        arbiter = Arbiter.new(@context)
        selected = arbiter.select([])

        assert_equal [], selected
      end

      test "returns single candidate for single-element array" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "round_robin" }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select([ @agent1 ])

        assert_equal [ @agent1 ], selected
      end

      test "falls back to all strategy for unknown strategy" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "unknown_strategy" }
        )

        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal @candidates, selected
      end

      test "defaults to all strategy when no policy exists" do
        arbiter = Arbiter.new(@context)
        selected = arbiter.select(@candidates)

        assert_equal @candidates, selected
      end
    end
  end
end
