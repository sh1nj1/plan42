# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class PolicyResolverTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @user = users(:one)
        @ai_agent = users(:ai_bot)
        @topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)

        @context = {
          "creative" => { "id" => @creative.id },
          "topic" => { "id" => @topic.id }
        }
      end

      test "returns default arbitration config when no policies exist" do
        resolver = PolicyResolver.new(@context)

        assert_equal "all", resolver.arbitration_strategy
        assert_nil resolver.max_responders
      end

      test "merges global policy config" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "primary_first", "max_responders" => 2 }
        )

        resolver = PolicyResolver.new(@context)

        assert_equal "primary_first", resolver.arbitration_strategy
        assert_equal 2, resolver.max_responders
      end

      test "creative policy overrides global policy" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          priority: 100,
          config: { "strategy" => "all", "max_responders" => 5 }
        )
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          scope_type: "Creative",
          scope_id: @creative.id,
          priority: 50,
          config: { "strategy" => "round_robin" }
        )

        resolver = PolicyResolver.new(@context)

        # Creative policy overrides strategy but not max_responders
        assert_equal "round_robin", resolver.arbitration_strategy
        assert_equal 5, resolver.max_responders
      end

      test "topic policy overrides creative policy" do
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          scope_type: "Creative",
          scope_id: @creative.id,
          priority: 50,
          config: { "strategy" => "round_robin", "primary_agent_id" => 999 }
        )
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          scope_type: "Topic",
          scope_id: @topic.id,
          priority: 25,
          config: { "strategy" => "primary_first" }
        )

        resolver = PolicyResolver.new(@context)

        # Topic overrides strategy, but primary_agent_id comes from creative
        assert_equal "primary_first", resolver.arbitration_strategy
        assert_equal 999, resolver.primary_agent_id
      end

      test "scheduling_config_for includes agent-specific overrides" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          config: { "max_concurrent_jobs" => 3 }
        )
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          scope_type: "User",
          scope_id: @ai_agent.id,
          config: { "max_concurrent_jobs" => 10, "daily_token_limit" => 500_000 }
        )

        resolver = PolicyResolver.new(@context)
        config = resolver.scheduling_config_for(@ai_agent)

        assert_equal 10, config["max_concurrent_jobs"]
        assert_equal 500_000, config["daily_token_limit"]
      end

      test "returns defaults for scheduling when no policies" do
        resolver = PolicyResolver.new(@context)
        config = resolver.scheduling_config_for(@ai_agent)

        assert_equal 5, config["max_concurrent_jobs"]
        assert_equal 100_000, config["daily_token_limit"]
        assert_equal 20, config["rate_limit_per_minute"]
      end

      test "topic primary_agent_id column takes precedence over policy config" do
        @topic.update!(primary_agent_id: @ai_agent.id)

        # Set a different primary_agent_id in creative-level policy
        other_agent = User.create!(
          name: "Other Agent",
          email: "other_#{SecureRandom.hex(4)}@example.com",
          password: "password",
          llm_vendor: "openai",
          searchable: true
        )
        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          scope_type: "Creative",
          scope_id: @creative.id,
          config: { "strategy" => "primary_first", "primary_agent_id" => other_agent.id }
        )

        resolver = PolicyResolver.new(@context)

        # Topic column should take precedence
        assert_equal @ai_agent.id, resolver.primary_agent_id
      end

      test "falls back to policy primary_agent_id when topic column is nil" do
        assert_nil @topic.primary_agent_id

        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "primary_first", "primary_agent_id" => @ai_agent.id }
        )

        resolver = PolicyResolver.new(@context)

        assert_equal @ai_agent.id, resolver.primary_agent_id
      end

      test "auto-selects primary_first strategy when topic has primary_agent_id" do
        @topic.update!(primary_agent_id: @ai_agent.id)

        resolver = PolicyResolver.new(@context)

        assert_equal "primary_first", resolver.arbitration_strategy
      end

      test "auto-selects primary_first strategy even when global policy sets different strategy" do
        @topic.update!(primary_agent_id: @ai_agent.id)

        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "round_robin" }
        )

        resolver = PolicyResolver.new(@context)

        assert_equal "primary_first", resolver.arbitration_strategy
      end

      test "uses policy strategy when topic has no primary_agent_id" do
        assert_nil @topic.primary_agent_id

        OrchestratorPolicy.create!(
          policy_type: "arbitration",
          config: { "strategy" => "round_robin" }
        )

        resolver = PolicyResolver.new(@context)

        assert_equal "round_robin", resolver.arbitration_strategy
      end
    end
  end
end
