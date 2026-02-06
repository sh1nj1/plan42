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
        create_agent_response("작업 완료했습니다. 확신도: 85")
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate

        assert_equal :done, result.action
        assert_equal 85, result.confidence
        assert_equal "threshold_met", result.reason
      end

      test "returns retry when confidence below threshold" do
        create_agent_response("작업을 시도했습니다. confidence: 50")
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70, max_retries: 3)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate

        assert_equal :retry, result.action
        assert_equal 50, result.confidence
        assert_equal "below_threshold", result.reason
      end

      test "returns retry when uncertainty detected without confidence" do
        create_agent_response("이 부분은 확실하지 않네요.")
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate

        assert_equal :retry, result.action
        assert_equal "uncertainty_detected", result.reason
      end

      test "returns escalate when max retries exceeded" do
        @task.update!(retry_count: 3)
        create_agent_response("confidence: 40")
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70, max_retries: 3)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate

        assert_equal :escalate, result.action
        assert_equal "max_retries_exceeded", result.reason
      end

      test "returns done when no confidence signal and no uncertainty" do
        create_agent_response("작업을 완료했습니다. 코드를 수정했습니다.")
        policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

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
          # Clean up previous response
          Collavre::Comment.where(topic_id: @topic.id, user_id: @agent.id).destroy_all

          create_agent_response(content)
          policy_resolver = mock_policy_resolver(enabled: true, threshold: 70)
          evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

          result = evaluator.evaluate
          assert_equal expected_confidence, result.confidence, "Failed to parse: #{content}"
        end
      end

      test "includes retry delay from policy" do
        create_agent_response("confidence: 50")
        policy_resolver = mock_policy_resolver(
          enabled: true,
          threshold: 70,
          retry_delay: 10
        )
        evaluator = SelfReflectionEvaluator.new(@task, policy_resolver: policy_resolver)

        result = evaluator.evaluate

        assert_equal :retry, result.action
        assert_equal 10, result.delay
      end

      private

      def create_agent_response(content)
        @creative.comments.create!(
          content: content,
          user: @agent,
          topic_id: @topic.id
        )
      end

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
