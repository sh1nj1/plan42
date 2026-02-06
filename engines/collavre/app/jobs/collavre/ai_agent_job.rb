module Collavre
  class AiAgentJob < ApplicationJob
    queue_as :default

    # Allow resuming a task that was pending approval
    def perform(agent_id_or_task, event_name = nil, context = nil)
      if agent_id_or_task.is_a?(Task)
        # Resume existing task
        task = agent_id_or_task
        return if task.reload.status == "cancelled"

        task.update!(status: "running")
        agent = task.agent
      else
        # Create new task
        agent = User.find(agent_id_or_task)
        task = Task.create!(
          name: "Response to #{event_name}",
          status: "running",
          trigger_event_name: event_name,
          trigger_event_payload: context,
          agent: agent,
          topic_id: context&.dig("topic", "id")
        )
      end

      # Reserve resources before starting work
      tracker = Orchestration::ResourceTracker.for(agent)
      tracker.reserve!(job_id || task.id)

      begin
        AiAgentService.new(task).call

        # Evaluate self-reflection if enabled
        reflection_result = evaluate_self_reflection(task)

        case reflection_result.action
        when :retry
          # Schedule retry with delay - don't release resources yet
          schedule_self_reflection_retry(task, reflection_result)
          Rails.logger.info(
            "[AiAgentJob] Task #{task.id} scheduled for retry " \
            "(attempt #{task.retry_count + 1}, confidence: #{reflection_result.confidence})"
          )
          nil # Exit without releasing resources or dequeuing
        when :escalate
          # Escalate to admins
          Orchestration::SelfReflectionEvaluator.new(task).escalate!
          tracker.release!(job_id || task.id, tokens_used: 0)
          Rails.logger.info("[AiAgentJob] Task #{task.id} escalated after max retries")
        else # :done
          task.update!(status: "done")
          tracker.release!(job_id || task.id, tokens_used: 0)
        end
      rescue ApprovalPendingError
        # Task status already set to pending_approval by AiAgentService
        # Don't release resources yet - task will resume
        Rails.logger.info("AiAgentJob paused for task #{task.id}: awaiting tool approval")
      rescue CancelledError
        # Task status already set to "cancelled" by Comment callback
        tracker.release!(job_id || task.id, tokens_used: 0)
        Rails.logger.info("AiAgentJob cancelled for task #{task.id}: trigger message deleted")
      rescue StandardError => e
        task.update!(status: "failed")
        tracker.release!(job_id || task.id, tokens_used: 0)
        Rails.logger.error("AiAgentJob failed for task #{task.id}: #{e.message}")
        raise e
      ensure
        if task&.topic_id && %w[done failed cancelled escalated].include?(task.reload.status)
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id)
        end
      end
    end

    private

    def evaluate_self_reflection(task)
      Orchestration::SelfReflectionEvaluator.new(task).evaluate
    end

    def schedule_self_reflection_retry(task, result)
      evaluator = Orchestration::SelfReflectionEvaluator.new(task)
      evaluator.schedule_retry!
    end
  end
end
