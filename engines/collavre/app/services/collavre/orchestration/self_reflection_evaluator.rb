# frozen_string_literal: true

module Collavre
  module Orchestration
    # SelfReflectionEvaluator evaluates an agent's response and determines
    # whether the agent should retry, escalate, or mark the task as done.
    #
    # It parses confidence signals from the response and compares against
    # policy-configured thresholds.
    #
    # Usage:
    #   evaluator = SelfReflectionEvaluator.new(task)
    #   result = evaluator.evaluate
    #   case result.action
    #   when :done then task.update!(status: "done")
    #   when :retry then schedule_retry(result.delay)
    #   when :escalate then notify_admin(result.reason)
    #   end
    #
    class SelfReflectionEvaluator
      Result = Struct.new(:action, :delay, :reason, :confidence, keyword_init: true)

      # Patterns to extract confidence from agent response
      CONFIDENCE_PATTERNS = [
        /확신도[:\s]*(\d+)/i,
        /confidence[:\s]*(\d+)/i,
        /\[confidence[:\s]*(\d+)\]/i,
        /확신[:\s]*(\d+)%?/i
      ].freeze

      # Patterns that indicate the agent is stuck or uncertain
      UNCERTAINTY_PATTERNS = [
        /잘\s*모르겠/,
        /확실하지\s*않/,
        /불확실/,
        /도움이?\s*필요/,
        /막혔/,
        /I('m| am)\s*(not sure|uncertain|stuck)/i,
        /need(s)?\s*help/i,
        /cannot\s*(proceed|continue)/i
      ].freeze

      def initialize(task, response_content: nil, policy_resolver: nil)
        @task = task
        @response_content = response_content || ""
        @policy_resolver = policy_resolver ||
          PolicyResolver.new(task.trigger_event_payload || {})
      end

      # Evaluate the task's response and return a Result
      # @return [Result] with :action (:done, :retry, :escalate), :delay, :reason, :confidence
      def evaluate
        return Result.new(action: :done, reason: "self_reflection_disabled") unless enabled?

        confidence = parse_confidence
        uncertainty_detected = detect_uncertainty

        if confidence.nil? && !uncertainty_detected
          # No confidence signal and no uncertainty - assume done
          Result.new(action: :done, confidence: nil, reason: "no_signal")
        elsif confidence && confidence >= threshold
          # Confidence meets threshold - done
          Result.new(action: :done, confidence: confidence, reason: "threshold_met")
        elsif @task.retry_count >= max_retries
          # Max retries exceeded - escalate
          Result.new(
            action: :escalate,
            confidence: confidence,
            reason: "max_retries_exceeded"
          )
        else
          # Below threshold or uncertainty detected - retry
          Result.new(
            action: :retry,
            delay: retry_delay,
            confidence: confidence,
            reason: uncertainty_detected ? "uncertainty_detected" : "below_threshold"
          )
        end
      end

      # Schedule a retry by creating a system message and re-triggering
      # @param result [Result] pre-computed result from evaluate
      def schedule_retry!(result)
        return result unless result.action == :retry

        # Increment retry count
        @task.increment!(:retry_count)

        # Create self-reflection prompt as a new comment
        create_reflection_prompt

        # Schedule the retry job
        if result.delay.positive?
          AiAgentJob.set(wait: result.delay.seconds).perform_later(@task)
        else
          AiAgentJob.perform_later(@task)
        end

        result
      end

      # Escalate to admin users
      # @param result [Result] pre-computed result from evaluate
      def escalate!(result)
        return result unless result.action == :escalate

        @task.update!(status: "escalated")
        create_escalation_notice
        notify_admins

        result
      end

      private

      def config
        @config ||= @policy_resolver.self_reflection_config
      end

      def enabled?
        config["enabled"] == true
      end

      def threshold
        config["confidence_threshold"] || 70
      end

      def max_retries
        config["max_retries"] || 3
      end

      def retry_delay
        config["retry_delay_seconds"] || 5
      end

      def response_content
        @response_content
      end

      def parse_confidence
        CONFIDENCE_PATTERNS.each do |pattern|
          match = response_content.match(pattern)
          return match[1].to_i if match
        end
        nil
      end

      def detect_uncertainty
        UNCERTAINTY_PATTERNS.any? { |pattern| response_content.match?(pattern) }
      end

      def create_reflection_prompt
        creative_id = @task.trigger_event_payload&.dig("creative", "id")
        return unless creative_id && @task.topic_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        # Create a system message prompting self-reflection
        creative.comments.create!(
          content: reflection_prompt_content,
          user: system_user,
          topic_id: @task.topic_id,
          private: false
        )
      end

      def reflection_prompt_content
        <<~PROMPT.strip
          [시스템] 확신도가 낮습니다 (#{@task.retry_count + 1}/#{max_retries} 재시도).

          다시 검토해주세요:
          - 다른 접근법이 있나요?
          - 부족한 정보가 있다면 @멘션으로 다른 Agent에게 요청하세요.
          - 그래도 해결이 어려우면 상위로 에스컬레이션하세요.

          응답 시 확신도를 명시해주세요: [confidence: 0-100]
        PROMPT
      end

      def create_escalation_notice
        creative_id = @task.trigger_event_payload&.dig("creative", "id")
        return unless creative_id && @task.topic_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        creative.comments.create!(
          content: escalation_notice_content,
          user: system_user,
          topic_id: @task.topic_id,
          private: false
        )
      end

      def escalation_notice_content
        <<~NOTICE.strip
          [시스템] ⚠️ 에스컬레이션 발생

          Agent: #{@task.agent&.name}
          작업: #{@task.name}
          재시도 횟수: #{@task.retry_count}회

          최대 재시도 횟수를 초과하여 관리자에게 에스컬레이션되었습니다.
          admin 권한을 가진 사용자의 검토가 필요합니다.
        NOTICE
      end

      def notify_admins
        # Find admin users for this creative and notify them
        creative_id = @task.trigger_event_payload&.dig("creative", "id")
        return unless creative_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        # This could trigger notifications via various channels
        # For now, the escalation notice in the topic serves as notification
        Rails.logger.info(
          "[SelfReflection] Task #{@task.id} escalated for creative #{creative_id}"
        )
      end

      def system_user
        @system_user ||= User.find_by(email: "system@collavre.local") ||
          @task.agent # Fallback to agent if no system user
      end
    end
  end
end
