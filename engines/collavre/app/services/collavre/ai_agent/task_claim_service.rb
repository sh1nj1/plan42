# frozen_string_literal: true

module Collavre
  module AiAgent
    # Atomically claims and finalizes a delegated task on behalf of a Claude
    # Channel /reply. Extracted from Api::V1::AgentsController#reply so the
    # controller only sequences: claim -> save comment -> finalize. Behavior is
    # identical to the inlined controller methods it replaces.
    class TaskClaimService
      # Atomically claim a delegated task for completion. Two-step:
      #   1. Find a candidate task in delegated state, scoped to this agent +
      #      topic. With task_id supplied, exact match (required under topic
      #      concurrency > 1 where multiple delegated tasks coexist; the client
      #      echoes the dispatch's task_id). Without task_id (legacy clients),
      #      oldest-first.
      #   2. Inside a transaction: SELECT FOR UPDATE the row, re-check
      #      status == 'delegated' under the lock, then update! to 'done'.
      #      Concurrent claimers block on the lock; the loser sees the
      #      already-flipped status post-lock and returns nil so the caller can
      #      refuse the duplicate.
      # update_all (NOT update!) is required to skip Task's after_update_commit
      # callbacks at claim time. The callbacks fire check_trigger_loop_completion
      # (which enqueues TriggerLoopCheckJob) and broadcast_stop_button_removal
      # (which reads reply_comment). Both depend on the reply comment already
      # existing — but reply() claims BEFORE comment.save to win the race against
      # concurrent /reply calls. If update! fired the trigger-loop check here, the
      # job could run (cooldown_seconds: 0) before comment.save commits, find no
      # agent comment, and leave the loop stuck in "running". #finalize replays
      # both callbacks after the comment is persisted via
      # Task#fire_completion_callbacks_after_external_claim.
      def claim(agent:, topic:, requested_task_id:)
        scope = Task.where(agent_id: agent.id, topic_id: topic.id, status: "delegated")
        candidate =
          if requested_task_id.present?
            scope.find_by(id: requested_task_id)
          else
            scope.order(:created_at).first
          end
        return nil unless candidate

        claimed = nil
        Task.transaction do
          locked = Task.lock.find_by(id: candidate.id)
          next unless locked && locked.status == "delegated"

          Task.where(id: locked.id).update_all(status: "done", pending_tool_call: nil, updated_at: Time.current)
          claimed = locked.reload
        end
        claimed
      end

      # Why #claim refused, so the caller can tell the one benign conflict from
      # the ones that lose a real reply.
      #
      # ALREADY_COMPLETED is the sibling-session dedup this whole claim exists
      # for: the dispatch WAS answered (by another session sharing this agent, or
      # by the agent's own job), so the reply being refused is a duplicate of one
      # that already landed. Dropping it is correct.
      #
      # NOT_DELEGATED is everything else: a task moved out of `delegated` without
      # a reply — cancelled by an offline session, failed, or recovered by the
      # stuck-task sweeper while the agent was still composing. Nothing answered
      # that dispatch, so the text the caller is holding is the only copy of that
      # answer and the conflict has to surface rather than be swallowed. A task
      # that cannot be found under this agent+topic reads the same way; the reply
      # path resolves the agent from the task first, so it should not reach here,
      # and the safe default if it ever does is "surface it".
      CONFLICT_ALREADY_COMPLETED = "already_completed"
      CONFLICT_NOT_DELEGATED = "not_delegated"

      def conflict_reason(agent:, topic:, requested_task_id:)
        task = Task.find_by(id: requested_task_id, agent_id: agent.id, topic_id: topic.id)
        task&.status == "done" ? CONFLICT_ALREADY_COMPLETED : CONFLICT_NOT_DELEGATED
      end

      # Post-claim side effects, run only after the reply comment is saved. Links
      # the comment to the claimed task, releases the ResourceTracker slot the
      # AiAgentJob held under task.id, advances the parent workflow (if any), and
      # drains the topic queue — mirroring AiAgentJob#perform's success path for
      # non-delegated runs.
      def finalize(agent:, task:, comment:)
        comment.update_column(:task_id, task.id)

        Orchestration::ResourceTracker.for(agent).release!(task.id)

        if task.parent_task_id.present?
          Collavre::Comments::WorkflowExecutor.new(task.parent_task).complete_subtask!(task)
        end

        Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)

        # Replay the after_update_commit callbacks that were bypassed by
        # update_all in #claim — now that the reply comment is linked,
        # TriggerLoopCheckJob can read it and decide whether to advance/await/
        # complete the drop-trigger loop, and the stop-button broadcast has a
        # comment to render.
        task.fire_completion_callbacks_after_external_claim

        # Clear the typing indicator immediately on reply. ClaudeChannelPresenceJob
        # would also stop on its next beat (task no longer "delegated"), but that
        # is up to HEARTBEAT_SECONDS away — broadcast idle now so the indicator
        # drops the moment Claude's reply lands.
        broadcast_claude_idle(agent, task, comment)
      end

      private

      # Clear the chat typing indicator via the canonical status broadcaster (the
      # same one AiAgentService uses for every other agent), so the Claude path
      # emits an identical "idle" agent_status payload.
      def broadcast_claude_idle(agent, task, comment)
        creative = comment.creative&.effective_origin
        return unless creative

        AiAgent::AgentLifecycleManager.new(task: task, agent: agent, creative: creative)
                                      .broadcast_status("idle")
      end
    end
  end
end
