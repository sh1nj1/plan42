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

      test "coalescing of un-started tasks is on by default" do
        assert PolicyResolver.new(@context).coalesce_pending_tasks_for?(@ai_agent)
      end

      test "coalescing can be turned off by policy" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          config: { "coalesce_pending_tasks" => false }
        )

        assert_not PolicyResolver.new(@context).coalesce_pending_tasks_for?(@ai_agent)
      end

      # Coalescing folds same-agent siblings, so User scope is the granularity
      # of the switch. scheduling_config excludes agent policies by
      # construction — reading it here was the same as ignoring the opt-out.
      test "coalescing can be turned off for one agent by a User-scoped policy" do
        OrchestratorPolicy.create!(
          policy_type: "scheduling", scope_type: "User", scope_id: @ai_agent.id,
          config: { "coalesce_pending_tasks" => false }
        )
        resolver = PolicyResolver.new(@context)

        assert_not resolver.coalesce_pending_tasks_for?(@ai_agent)
        assert resolver.coalesce_pending_tasks_for?(users(:channel_bot)),
          "a User-scoped policy must not answer for a different agent"
      end

      # Every policy type keeps global < creative < topic precedence now that
      # all of them come from one read.
      {
        "matching" => "workflow_routing",
        "arbitration" => "strategy",
        "scheduling" => "max_concurrent_jobs",
        "stuck_detection" => "task_stuck_threshold_minutes",
        "collaboration" => "mention_rule"
      }.each do |policy_type, key|
        test "#{policy_type} policies keep scope precedence from a single read" do
          OrchestratorPolicy.create!(policy_type: policy_type, priority: 1,
                                     config: { key => "global", "global_only" => true })
          OrchestratorPolicy.create!(policy_type: policy_type, scope_type: "Creative", scope_id: @creative.id,
                                     priority: 900, config: { key => "creative", "creative_only" => true })
          OrchestratorPolicy.create!(policy_type: policy_type, scope_type: "Topic", scope_id: @topic.id,
                                     priority: 0, config: { key => "topic" })
          OrchestratorPolicy.create!(policy_type: policy_type, scope_type: "Topic", scope_id: @topic.id,
                                     enabled: false, config: { key => "disabled" })

          config = PolicyResolver.new(@context).resolve(policy_type)

          assert_equal "topic", config[key]
          assert config["global_only"]
          assert config["creative_only"]
        end
      end

      test "one resolver reads context policies once for every policy type" do
        OrchestratorPolicy.create!(policy_type: "matching", config: { "workflow_routing" => "off" })
        OrchestratorPolicy.create!(policy_type: "arbitration", scope_type: "Creative", scope_id: @creative.id,
                                   config: { "strategy" => "round_robin" })
        OrchestratorPolicy.create!(policy_type: "scheduling", scope_type: "Topic", scope_id: @topic.id,
                                   config: { "topic_max_concurrent_jobs" => 3 })
        resolver = PolicyResolver.new(@context)

        assert_queries_match(/orchestrator_policies/, count: 1) do
          assert_equal "off", resolver.workflow_routing_mode
          assert_equal "round_robin", resolver.arbitration_config["strategy"]
          assert_equal 3, resolver.topic_max_concurrent_jobs
          assert resolver.loop_breaker_enabled?
          assert resolver.stuck_detection_enabled?
          assert_nil resolver.collaboration_config["mention_rule"]
        end
      end

      test "agent scheduling policies are read once per agent" do
        other_agent = users(:channel_bot)
        OrchestratorPolicy.create!(policy_type: "scheduling", config: { "max_concurrent_jobs" => 3 })
        OrchestratorPolicy.create!(policy_type: "scheduling", scope_type: "User", scope_id: @ai_agent.id,
                                   config: { "max_concurrent_jobs" => 7 })
        resolver = PolicyResolver.new(@context)

        assert_queries_match(/orchestrator_policies/, count: 3) do
          2.times do
            assert_equal 7, resolver.scheduling_config_for(@ai_agent)["max_concurrent_jobs"]
            assert_equal 3, resolver.scheduling_config_for(other_agent)["max_concurrent_jobs"]
          end
        end
        assert_equal 3, resolver.scheduling_config["max_concurrent_jobs"]
      end

      test "ignoring_topic_primary reuses the loaded policies but not the pin" do
        @topic.update!(primary_agent_id: @ai_agent.id)
        OrchestratorPolicy.create!(policy_type: "arbitration",
                                   config: { "strategy" => "round_robin", "primary_agent_id" => 42 })
        resolver = PolicyResolver.new(@context)
        assert_equal "primary_first", resolver.arbitration_strategy
        assert_nil resolver.max_responders

        unpinned = resolver.ignoring_topic_primary
        assert_no_queries_match(/orchestrator_policies|FROM "topics"/) do
          assert_equal "round_robin", unpinned.arbitration_strategy
          assert_nil unpinned.topic_primary_agent_id
          assert_equal 42, unpinned.primary_agent_id
        end
      end

      test "topic_primary_agent_id reads the dispatch's topic record" do
        @topic.update!(primary_agent_id: @ai_agent.id)
        records = DispatchRecords.new.seed(@topic)
        resolver = PolicyResolver.new(@context, records: records)

        assert_no_queries_match(/FROM "topics"/) do
          assert_equal @ai_agent.id, resolver.topic_primary_agent_id
          assert_equal @ai_agent.id, resolver.primary_agent_id
        end
      end

      test "a new resolver sees policy changes made after an earlier one read" do
        first = PolicyResolver.new(@context)
        assert_equal "all", first.arbitration_strategy

        OrchestratorPolicy.create!(policy_type: "arbitration", scope_type: "Topic", scope_id: @topic.id,
                                   config: { "strategy" => "round_robin" })
        @topic.update!(primary_agent_id: @ai_agent.id)

        second = PolicyResolver.new(@context, records: DispatchRecords.new)
        assert_equal "round_robin", second.arbitration_config["strategy"]
        assert_equal @ai_agent.id, second.topic_primary_agent_id
        assert_equal "primary_first", second.arbitration_strategy
      end
    end
  end
end
