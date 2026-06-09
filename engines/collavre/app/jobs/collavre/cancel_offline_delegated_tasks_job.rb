# frozen_string_literal: true

module Collavre
  # Reconnect-grace cancellation for delegated tasks owned by a Claude Channel
  # session whose WebSocket dropped without DELETE /api/v1/agent/:id.
  #
  # AgentChannel#unsubscribed makes the agent unroutable, but a task already
  # in "delegated" still holds its ResourceTracker slot and (for workflow
  # subtasks) blocks the parent workflow. The dispatch was broadcast to a
  # now-dead stream, so no client remains to call /reply — without this job
  # the slot stays held until StuckDetectorJob times out (minutes to hours).
  #
  # The grace delay lets transient WS blips self-heal: if the client
  # reconnects before the job fires, AgentChannel#subscribe_to_agent_stream
  # restores routing_expression to "true" and writes a fresh subscription
  # token. The job's online-state recheck then no-ops.
  class CancelOfflineDelegatedTasksJob < ApplicationJob
    queue_as :default

    GRACE_SECONDS = 30

    def perform(agent_id, expected_token, session_id = nil)
      agent = User.find_by(id: agent_id)
      return unless agent&.claude_channel_agent?

      # Session-scoped variant: a live sibling may keep the shared agent
      # routable (so the agent-wide rechecks below would no-op), but the
      # dropped session's OWN session topic is private to it — siblings filter
      # session_topic dispatches to their own topic, so none will /reply. Cancel
      # only that topic's delegated work. Enqueued by AgentChannel#unsubscribed
      # when a sibling remains; mirrors the destroy path's cancel_tasks_for_topic.
      return cancel_dropped_session_tasks(agent, session_id) if session_id.present?

      # Agent came back online during the grace window — the same MCP
      # session (or a new one) is subscribed and can answer /reply.
      return if agent.routing_expression.present?

      # A session (reconnect or a still-live sibling sharing this agent) holds
      # a LIVE presence row — the agent is online, its delegated work is still
      # owned. Presence is the authority now that one agent fans out to many
      # concurrent sessions. Reap crash-orphaned rows first so a dead process's
      # leftover row can't masquerade as a live session and strand this work.
      AgentSubscription.reap_stale!(agent.id)
      return if AgentSubscription.live.where(agent_id: agent.id).exists?

      # A different subscription has taken over (token rotated). The new
      # session's lifecycle owns its own cancellation; don't double-cancel.
      if expected_token.present? &&
         agent.routing_subscription_token.present? &&
         agent.routing_subscription_token != expected_token
        return
      end

      cancel_delegated_tasks(Task.where(agent_id: agent.id, status: "delegated"), agent)
    end

    private

    # Cancel only the dropped session's own session-topic delegated work, unless
    # this same session reconnected within the grace window (a fresh live row
    # under the same session_id). Work on OTHER topics is fan-out — any live
    # sibling can still claim it — so it is deliberately left untouched.
    def cancel_dropped_session_tasks(agent, session_id)
      AgentSubscription.reap_stale!(agent.id)
      return if AgentSubscription.live.where(agent_id: agent.id, session_id: session_id).exists?

      topic = Topic.find_by(primary_agent_id: agent.id, session_id: session_id)
      return unless topic

      cancel_delegated_tasks(
        Task.where(agent_id: agent.id, topic_id: topic.id, status: "delegated"), agent
      )
    end

    def cancel_delegated_tasks(tasks, agent)
      return if tasks.empty?

      tracker = Orchestration::ResourceTracker.for(agent)
      tasks.find_each do |task|
        task.update!(status: "cancelled")
        tracker.release!(task.id)

        if task.parent_task_id.present?
          begin
            Collavre::Comments::WorkflowExecutor.new(task.parent_task).fail_subtask!(
              task, error_message: "Claude Channel session lost connection before reply"
            )
          rescue StandardError => e
            Rails.logger.error(
              "[CancelOfflineDelegatedTasksJob] fail_subtask! failed for task #{task.id}: #{e.message}"
            )
          end
        end

        if task.topic_id.present?
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
        end
      end
    end
  end
end
