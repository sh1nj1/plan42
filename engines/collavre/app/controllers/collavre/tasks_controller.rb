# frozen_string_literal: true

module Collavre
  class TasksController < ApplicationController
    def active_statuses
      task_ids = params[:task_ids].to_s.split(",").map(&:to_i).reject(&:zero?)
      return render json: { tasks: [] } if task_ids.empty?

      tasks = Task.where(id: task_ids).includes(:creative)
      results = tasks.filter_map do |task|
        creative = task.creative || Creative.find_by(id: task.trigger_event_payload&.dig("creative", "id"))
        next unless creative&.has_permission?(Current.user, :read)

        { id: task.id, active: task.active? }
      end

      render json: { tasks: results }
    end

    def cancel
      task = Task.find(params[:id])
      creative = task.creative || Creative.find_by(id: task.trigger_event_payload&.dig("creative", "id"))

      unless creative && creative.has_permission?(Current.user, :feedback)
        return head :forbidden
      end

      # These statuses count against the topic slot (occupying_topic_slot) yet no
      # live worker will run AiAgentJob's ensure-block drain for them:
      #   - delegated / pending_approval already returned from the job holding the
      #     slot (should_release = false) — awaiting an MCP reply / approval.
      #   - pending may be a waiter that dequeue_next_for_topic promoted
      #     queued -> pending before its job starts; once cancelled, that job
      #     early-returns at the top of #perform and never reaches the ensure drain.
      # So free the agent slot and drain the topic queue here — otherwise
      # cancelling the blocker leaves agent capacity and the next waiter stuck
      # until stuck recovery. release!/dequeue are idempotent (dequeue is bounded
      # by topic_at_capacity?), so a racing live worker that also drains is harmless.
      held_slot_without_worker = nil
      task.with_lock do
        task.reload
        unless %w[running pending queued pending_approval delegated].include?(task.status)
          head :unprocessable_entity
          next
        end

        held_slot_without_worker = Task::HELD_SLOT_WITHOUT_WORKER.include?(task.status)
        task.update!(status: "cancelled")
      end
      return if performed?

      # The third door a waiter leaves the queue through without ever being
      # promoted — "queued" is in the whitelist above, so the user's own stop
      # button is one of them. Its "task" notice names this task, and a notice
      # naming a task that is no longer queued cancels nothing when dismissed:
      # a stop button for work that can no longer be stopped. Nothing else
      # collects it either — the task is never promoted, so
      # cleanup_waiter_notice! never runs for it, and the drained sweep needs
      # the topic queue to empty, which any sibling waiter prevents.
      Comment.remove_waiter_notices!(
        creative_id: task.creative_id, topic_id: task.topic_id, task_ids: task.id
      )

      # With coalescing on this waiter had no notice of its own — the topic's
      # shared one spoke for it, and the call above deliberately does not touch
      # that kind. Same stranding, one row over.
      if task.creative_id
        Comment.remove_stranded_waiting_notices!(
          creative_id: task.creative_id, topic_id: task.topic_id
        )
      end

      if held_slot_without_worker && task.agent
        Collavre::Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end

      abort_agent_session(task)

      head :ok
    end

    private

    def abort_agent_session(task)
      Collavre::AgentSessionAbort.call(agent: task.agent, task: task)
    end
  end
end
