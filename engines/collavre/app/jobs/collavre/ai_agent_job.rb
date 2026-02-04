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

      begin
        AiAgentService.new(task).call
        task.update!(status: "done")
      rescue ApprovalPendingError
        # Task status already set to pending_approval by AiAgentService
        # Don't mark as failed, just let the job complete gracefully
        Rails.logger.info("AiAgentJob paused for task #{task.id}: awaiting tool approval")
      rescue CancelledError
        # Task status already set to "cancelled" by Comment callback
        Rails.logger.info("AiAgentJob cancelled for task #{task.id}: trigger message deleted")
      rescue StandardError => e
        task.update!(status: "failed")
        Rails.logger.error("AiAgentJob failed for task #{task.id}: #{e.message}")
        raise e
      end
    end
  end
end
