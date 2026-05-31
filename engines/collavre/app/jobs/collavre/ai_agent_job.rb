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

        # Guard: skip if there's already a running task for the same agent + comment
        comment_id = context&.dig("comment", "id")
        if comment_id && Task.duplicate_running_for_comment?(agent.id, comment_id)
          Rails.logger.warn(
            "[AiAgentJob] Skipping duplicate: agent #{agent.id} already has a running task " \
            "for comment #{comment_id} (event=#{event_name})"
          )
          return
        end

        task = Task.create!(
          name: "Response to #{event_name}",
          status: "running",
          trigger_event_name: event_name,
          trigger_event_payload: context,
          agent: agent,
          topic_id: context&.dig("topic", "id"),
          creative_id: context&.dig("creative", "id")
        )

        # Record task for loop breaker tracking (per-topic, skip user-initiated)
        creative_id = context&.dig("creative", "id")
        if creative_id
          from_ai = context&.dig("comment", "from_ai") == true
          topic_id = context&.dig("topic", "id")
          Orchestration::LoopBreaker.new(context).record_task(
            creative_id, agent.id, topic_id: topic_id, triggered_by_user: !from_ai
          )
        end
      end

      # Reserve resources before starting work
      tracker = Orchestration::ResourceTracker.for(agent)
      # Claude Channel tasks live past this job (MCP reply happens later), so
      # reserve under the stable task.id — that's the key reply / cancel /
      # stuck-recovery will use to release the slot.
      is_claude_channel_agent = agent.claude_channel_agent?
      resource_id = is_claude_channel_agent ? task.id : (job_id || task.id)
      tracker.reserve!(resource_id)
      should_release = true

      begin
        # For Claude Channel agents, transition to "delegated" BEFORE dispatching.
        # The MCP client can receive the broadcast and POST /reply on a different
        # thread before AiAgentService#call returns; the reply handler only looks
        # for status: "delegated" tasks, so a late update! would leave the
        # already-answered task stuck in delegated until stuck recovery.
        if is_claude_channel_agent
          # Atomic running -> delegated transition. If AgentsController#destroy
          # races us between reserve! above and this line and flips the task
          # to "cancelled", the WHERE filter excludes us, rows_updated == 0,
          # we skip dispatch, and the ensure block releases the slot. A
          # separate reload + update! would let the cancel slip in between.
          rows_updated = Task.where(id: task.id, status: "running").update_all(
            status: "delegated", updated_at: Time.current
          )
          if rows_updated.zero?
            task.reload
            Rails.logger.info(
              "[AiAgentJob] Claude Channel task #{task.id} not in running state " \
              "(status=#{task.status}); skipping dispatch"
            )
            return
          end
          task.reload
        end

        response_content = AiAgentService.new(task).call

        # Claude Channel agents delegate via MCP; no immediate response expected
        if is_claude_channel_agent
          # Hold agent capacity until reply / cancel / stuck-recovery releases it.
          should_release = false
        # Workflow subtasks with empty responses should retry, then fail
        elsif task.parent_task_id.present? && response_content.blank?
          max_retries = 2
          current_retry = task.retry_count || 0

          if current_retry < max_retries
            task.update!(retry_count: current_retry + 1, status: "pending")
            Rails.logger.warn(
              "[AiAgentJob] Workflow subtask #{task.id} returned empty response, " \
              "retrying (#{current_retry + 1}/#{max_retries})"
            )
            AiAgentJob.set(wait: 5.seconds).perform_later(task)
          else
            task.update!(status: "failed")
            Collavre::Comments::WorkflowExecutor.new(task.parent_task).fail_subtask!(
              task, error_message: "Agent returned empty response after #{max_retries} retries"
            )
          end
        else
          task.update!(status: "done")
          # Advance workflow (release happens in ensure block)
          if task.parent_task_id.present?
            Collavre::Comments::WorkflowExecutor.new(task.parent_task).complete_subtask!(task)
          end
        end
      rescue ApprovalPendingError
        # Task status already set to pending_approval by AiAgentService
        # Don't release resources yet - task will resume
        should_release = false
        Rails.logger.info("AiAgentJob paused for task #{task.id}: awaiting tool approval")
      rescue CancelledError
        # Task status already set to "cancelled" by Comment callback
        Rails.logger.info("AiAgentJob cancelled for task #{task.id}: trigger message deleted")
      rescue StandardError => e
        task.update!(status: "failed")
        # Fail workflow if this is a sub-task
        if task.parent_task_id.present?
          Collavre::Comments::WorkflowExecutor.new(task.parent_task).fail_subtask!(task, error_message: e.message)
        end
        Rails.logger.error("AiAgentJob failed for task #{task.id}: #{e.message}")
        raise e
      ensure
        # Guarantee resource release for all paths except pending_approval
        tracker.release!(resource_id, tokens_used: 0) if should_release && tracker && resource_id
        if task&.trigger_event_payload&.key?("topic") && %w[done failed cancelled escalated].include?(task.reload.status)
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
        end
      end
    end
  end
end
