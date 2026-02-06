require "test_helper"

module Collavre
  module Orchestration
    class LoopBreakerTest < ActiveSupport::TestCase
      setup do
        @agent1 = Collavre::User.create!(
          name: "agent-1",
          email: "agent1-#{SecureRandom.hex(4)}@test.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4"
        )

        @agent2 = Collavre::User.create!(
          name: "agent-2",
          email: "agent2-#{SecureRandom.hex(4)}@test.test",
          password: "password123",
          llm_vendor: "openai",
          llm_model: "gpt-4"
        )

        @human = Collavre::User.create!(
          name: "human",
          email: "human-#{SecureRandom.hex(4)}@test.test",
          password: "password123"
        )

        @creative = Collavre::Creative.create!(
          description: "Test Creative",
          user: @human
        )

        @context = {
          "creative" => { "id" => @creative.id },
          "agent" => { "id" => @agent1.id }
        }

        @enabled_config = {
          "loop_breaker_enabled" => true,
          "ping_pong_threshold" => 3,
          "creative_retry_threshold" => 5,
          "creative_retry_window_minutes" => 30,
          "task_timeout_minutes" => 60,
          "token_spike_threshold" => 10_000,
          "token_spike_window_minutes" => 10
        }

        # Clear cache before each test
        Rails.cache.clear
      end

      test "returns safe when disabled" do
        breaker = LoopBreaker.new(@context)
        result = breaker.check

        assert result.safe?
        assert_not result.should_break?
      end

      test "detects ping-pong between agents" do
        policy = create_policy(@enabled_config)
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record exchanges (A→B, B→A, A→B, B→A = 3 exchanges)
        breaker.record_interaction(@agent1.id, @agent2.id, @creative.id)
        breaker.record_interaction(@agent2.id, @agent1.id, @creative.id)
        breaker.record_interaction(@agent1.id, @agent2.id, @creative.id)
        breaker.record_interaction(@agent2.id, @agent1.id, @creative.id)

        result = breaker.check

        assert result.should_break?
        assert_equal :ping_pong, result.reason
        assert_equal @creative.id, result.details[:creative_id]
      end

      test "allows interactions below ping-pong threshold" do
        policy = create_policy(@enabled_config)
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record only 2 exchanges (below threshold of 3)
        breaker.record_interaction(@agent1.id, @agent2.id, @creative.id)
        breaker.record_interaction(@agent2.id, @agent1.id, @creative.id)

        result = breaker.check

        assert result.safe?
      end

      test "detects creative retry exceeded" do
        policy = create_policy(@enabled_config)
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record 5 tasks (equals threshold)
        5.times do |i|
          breaker.record_task(@creative.id, @agent1.id)
        end

        result = breaker.check

        assert result.should_break?
        assert_equal :creative_retry_exceeded, result.reason
        assert_equal 5, result.details[:task_count]
      end

      test "allows tasks below creative retry threshold" do
        policy = create_policy(@enabled_config)
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record 4 tasks (below threshold of 5)
        4.times { breaker.record_task(@creative.id, @agent1.id) }

        result = breaker.check

        assert result.safe?
      end

      test "detects task timeout" do
        # Create a topic for the task
        topic = Collavre::Topic.create!(user: @human, name: "Test Topic", creative: @creative)

        context_with_topic = @context.merge("topic" => { "id" => topic.id })
        policy = create_policy(@enabled_config.merge("task_timeout_minutes" => 1))
        resolver = PolicyResolver.new(context_with_topic)
        breaker = LoopBreaker.new(context_with_topic, policy_resolver: resolver)

        # Create a running task that's been running too long
        task = Task.create!(
          name: "Long running task",
          status: "running",
          agent: @agent1,
          topic_id: topic.id,
          created_at: 2.minutes.ago
        )

        result = breaker.check

        assert result.should_break?
        assert_equal :task_timeout, result.reason
        assert_equal task.id, result.details[:task_id]
      end

      test "allows tasks within timeout" do
        # Create a topic for the task
        topic = Collavre::Topic.create!(user: @human, name: "Test Topic", creative: @creative)

        context_with_topic = @context.merge("topic" => { "id" => topic.id })
        policy = create_policy(@enabled_config.merge("task_timeout_minutes" => 60))
        resolver = PolicyResolver.new(context_with_topic)
        breaker = LoopBreaker.new(context_with_topic, policy_resolver: resolver)

        # Create a running task that's still within timeout
        Task.create!(
          name: "Recent task",
          status: "running",
          agent: @agent1,
          topic_id: topic.id,
          created_at: 10.minutes.ago
        )

        result = breaker.check

        assert result.safe?
      end

      test "detects token spike" do
        policy = create_policy(@enabled_config.merge("token_spike_threshold" => 1000))
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record token usage that exceeds threshold
        breaker.record_tokens(@agent1.id, 500)
        breaker.record_tokens(@agent1.id, 600)

        result = breaker.check

        assert result.should_break?
        assert_equal :token_spike, result.reason
        assert_equal 1100, result.details[:tokens_used]
      end

      test "allows token usage below spike threshold" do
        policy = create_policy(@enabled_config.merge("token_spike_threshold" => 10_000))
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record token usage below threshold
        breaker.record_tokens(@agent1.id, 500)

        result = breaker.check

        assert result.safe?
      end

      test "reset clears tracking for creative" do
        policy = create_policy(@enabled_config)
        resolver = PolicyResolver.new(@context)
        breaker = LoopBreaker.new(@context, policy_resolver: resolver)

        # Record tasks that would trigger break
        5.times { breaker.record_task(@creative.id, @agent1.id) }

        # Reset
        breaker.reset_for_creative(@creative.id)

        # Now should be safe
        result = breaker.check
        assert result.safe?
      end

      private

      def create_policy(config)
        OrchestratorPolicy.create!(
          policy_type: "scheduling",
          config: config
        )
      end
    end
  end
end
