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
          agent: agent
        )
      end

      # Reserve resources before starting work
      tracker = Orchestration::ResourceTracker.for(agent)
      tracker.reserve!(job_id || task.id)

      begin
        AiAgentService.new(task).call
        task.update!(status: "done")

        # Release resources on success
        # TODO: Track actual token usage from AiAgentService
        tracker.release!(job_id || task.id, tokens_used: 0)
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
      end
    end
  end
end
