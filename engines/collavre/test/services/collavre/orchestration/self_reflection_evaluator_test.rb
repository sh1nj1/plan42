# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class SelfReflectionEvaluatorTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        @agent = users(:ai_bot)
        @creative = creatives(:tshirt)

        # Create topic for testing
        @topic = Collavre::Topic.create!(
          name: "Test Topic",
          creative: @creative,
          user: @user
        )

        @task = Collavre::Task.create!(
          name: "Test task",
          status: "running",
          agent: @agent,
          topic_id: @topic.id,
          trigger_event_name: "comment_created",
          trigger_event_payload: {
            "creative" => { "id" => @creative.id },
            "topic" => { "id" => @topic.id }
          },
          retry_count: 0
        )
      end

      teardown do
        @topic&.destroy
      end

      test "returns done when self_reflection is disabled" do
        policy_resolver = mock_policy_resolver(enabled: false)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate

        assert_equal :done, result.action
        assert_equal "self_reflection_disabled", result.reason
      end

      test "returns done when confidence meets threshold" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "작업 완료했습니다. 확신도: 85",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate

        assert_equal :done, result.action
        assert_equal 85, result.confidence
        assert_equal "threshold_met", result.reason
      end

      test "returns retry when confidence below threshold" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70, max_retries: 3)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "작업을 시도했습니다. confidence: 50",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate

        assert_equal :retry, result.action
        assert_equal 50, result.confidence
        assert_equal "below_threshold", result.reason
      end

      test "returns retry when uncertainty detected without confidence" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "이 부분은 확실하지 않네요.",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate

        assert_equal :retry, result.action
        assert_equal "uncertainty_detected", result.reason
      end

      test "returns escalate when max retries exceeded" do
        @task.update!(retry_count: 3)
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70, max_retries: 3)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 40",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate

        assert_equal :escalate, result.action
        assert_equal "max_retries_exceeded", result.reason
      end

      test "returns done when no confidence signal and no uncertainty" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "작업을 완료했습니다. 코드를 수정했습니다.",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate

        assert_equal :done, result.action
        assert_equal "no_signal", result.reason
      end

      test "parses various confidence formats" do
        test_cases = [
          [ "확신도: 75", 75 ],
          [ "confidence: 80", 80 ],
          [ "[confidence: 90]", 90 ],
          [ "확신 65%", 65 ]
        ]

        test_cases.each do |content, expected_confidence|
          policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
          evaluator = SelfReflectionEvaluator.new(
            @task,
            response_content: content,
            policy_resolver: policy_resolver
          )

          result = evaluator.evaluate
          assert_equal expected_confidence, result.confidence, "Failed to parse: #{content}"
        end
      end

      test "includes retry delay from policy" do
        policy_resolver = mock_policy_resolver(
          enabled: true,
          threshold: 70,
          retry_delay: 10
        )
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 50",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate

        assert_equal :retry, result.action
        assert_equal 10, result.delay
      end

      test "schedule_retry! increments retry_count" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70, retry_delay: 0)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 50",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate
        assert_equal :retry, result.action
        assert_equal 0, @task.retry_count

        returned = evaluator.schedule_retry!(result)
        assert_equal :retry, returned.action
        assert_equal 1, @task.reload.retry_count
      end

      test "schedule_retry! returns result without action when not retry" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 90",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate
        assert_equal :done, result.action

        returned = evaluator.schedule_retry!(result)
        assert_equal :done, returned.action
        assert_equal 0, @task.reload.retry_count
      end

      test "escalate! sets task status to escalated" do
        @task.update!(retry_count: 3)
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70, max_retries: 3)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 40",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate
        assert_equal :escalate, result.action

        evaluator.escalate!(result)
        assert_equal "escalated", @task.reload.status
      end

      test "escalate! returns result without action when not escalate" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 90",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate
        assert_equal :done, result.action

        returned = evaluator.escalate!(result)
        assert_equal :done, returned.action
      end

      test "does not query database for response content" do
        # Create a comment in DB with different content to prove DB is not queried
        @creative.comments.create!(
          content: "confidence: 10",
          user: @agent,
          topic_id: @topic.id
        )

        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(
          @task,
          response_content: "confidence: 90",
          policy_resolver: policy_resolver
        )

        result = evaluator.evaluate
        # Should use passed content (90), not DB content (10)
        assert_equal :done, result.action
        assert_equal 90, result.confidence
      end

      test "defaults to empty response content when not provided" do
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate
        assert_equal :done, result.action
        assert_equal "no_signal", result.reason
      end

      private

      def mock_policy_resolver(enabled: false, threshold: 70, max_retries: 3, retry_delay: 5)
        resolver = Minitest::Mock.new
        config = {
          "enabled" => enabled,
          "confidence_threshold" => threshold,
          "max_retries" => max_retries,
          "retry_delay_seconds" => retry_delay
        }
        resolver.expect(:self_reflection_config, config)
        resolver
      end
    end
  end
end
