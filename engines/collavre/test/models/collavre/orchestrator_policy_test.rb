# frozen_string_literal: true

require "test_helper"

module Collavre
  class OrchestratorPolicyTest < ActiveSupport::TestCase
    setup do
      @creative = creatives(:tshirt)
      @user = users(:one)
      @ai_agent = users(:ai_bot)
      @topic = Topic.create!(name: "Test Topic", creative: @creative, user: @user)
    end

    test "validates policy_type presence" do
      policy = OrchestratorPolicy.new(config: {})
      assert_not policy.valid?
      assert_includes policy.errors[:policy_type], "can't be blank"
    end

    test "validates policy_type inclusion" do
      policy = OrchestratorPolicy.new(policy_type: "invalid", config: {})
      assert_not policy.valid?
      assert_includes policy.errors[:policy_type], "is not included in the list"
    end

    test "accepts valid policy_types" do
      %w[matching arbitration scheduling].each do |type|
        policy = OrchestratorPolicy.new(policy_type: type, config: {})
        policy.valid?
        assert_not_includes policy.errors[:policy_type], "is not included in the list"
      end
    end

    test "global? returns true for global policies" do
      policy = OrchestratorPolicy.new(
        policy_type: "arbitration",
        scope_type: nil,
        scope_id: nil
      )
      assert policy.global?
    end

    test "global? returns false for scoped policies" do
      policy = OrchestratorPolicy.new(
        policy_type: "arbitration",
        scope_type: "Creative",
        scope_id: 1
      )
      assert_not policy.global?
    end

    test "config_value returns value with string key" do
      policy = OrchestratorPolicy.new(
        policy_type: "arbitration",
        config: { "strategy" => "primary_first" }
      )
      assert_equal "primary_first", policy.config_value("strategy")
    end

    test "config_value returns default when key missing" do
      policy = OrchestratorPolicy.new(
        policy_type: "arbitration",
        config: {}
      )
      assert_equal "all", policy.config_value("strategy", default: "all")
    end

    test "arbitration_strategy returns strategy from config" do
      policy = OrchestratorPolicy.new(
        policy_type: "arbitration",
        config: { "strategy" => "round_robin" }
      )
      assert_equal "round_robin", policy.arbitration_strategy
    end

    test "arbitration_strategy returns nil for non-arbitration policies" do
      policy = OrchestratorPolicy.new(
        policy_type: "scheduling",
        config: { "strategy" => "something" }
      )
      assert_nil policy.arbitration_strategy
    end

    test "for_context returns global policies" do
      global_policy = OrchestratorPolicy.create!(
        policy_type: "arbitration",
        config: { "strategy" => "all" }
      )

      context = { "creative" => { "id" => 999 } }
      policies = OrchestratorPolicy.for_context(context, policy_type: "arbitration")

      assert_includes policies, global_policy
    end

    test "for_context returns creative-scoped policies" do
      creative_policy = OrchestratorPolicy.create!(
        policy_type: "arbitration",
        scope_type: "Creative",
        scope_id: @creative.id,
        config: { "strategy" => "primary_first" }
      )

      context = { "creative" => { "id" => @creative.id } }
      policies = OrchestratorPolicy.for_context(context, policy_type: "arbitration")

      assert_includes policies, creative_policy
    end

    test "for_context returns policies sorted by priority" do
      high_priority = OrchestratorPolicy.create!(
        policy_type: "arbitration",
        priority: 10,
        config: { "strategy" => "all" }
      )
      low_priority = OrchestratorPolicy.create!(
        policy_type: "arbitration",
        priority: 100,
        config: { "strategy" => "primary_first" }
      )

      policies = OrchestratorPolicy.for_context({}, policy_type: "arbitration")

      high_idx = policies.index(high_priority)
      low_idx = policies.index(low_priority)
      assert high_idx < low_idx, "Higher priority (lower number) should come first"
    end

    test "for_agent returns agent-scoped policies" do
      agent_policy = OrchestratorPolicy.create!(
        policy_type: "scheduling",
        scope_type: "User",
        scope_id: @ai_agent.id,
        config: { "max_concurrent_jobs" => 10 }
      )

      policies = OrchestratorPolicy.for_agent(@ai_agent.id, policy_type: "scheduling")

      assert_includes policies, agent_policy
    end

    test "enabled scope filters disabled policies" do
      enabled_policy = OrchestratorPolicy.create!(
        policy_type: "arbitration",
        enabled: true,
        config: {}
      )
      OrchestratorPolicy.create!(
        policy_type: "arbitration",
        enabled: false,
        config: {}
      )

      policies = OrchestratorPolicy.enabled.for_type("arbitration")

      assert_includes policies, enabled_policy
      assert_equal 1, policies.count
    end
  end
end
