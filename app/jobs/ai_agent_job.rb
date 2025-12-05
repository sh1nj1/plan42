class AiAgentJob < ApplicationJob
  queue_as :default

  def perform(agent_id, event_name, context)
    agent = User.find(agent_id)

    # Create Task
    task = Task.create!(
      name: "Response to #{event_name}",
      status: "running",
      trigger_event_name: event_name,
      trigger_event_payload: context,
      agent: agent
    )

    begin
      AiAgentService.new(task).call
      task.update!(status: "done")
    rescue StandardError => e
      task.update!(status: "failed")
      Rails.logger.error("AiAgentJob failed for task #{task.id}: #{e.message}")
      raise e
    end
  end
end
