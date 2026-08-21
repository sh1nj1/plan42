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
      # CLAIMED_WITHOUT_REPLY is the same `done` status with no answer behind it.
      # #claim flips the task to done BEFORE the controller saves the comment, so
      # between those two statements the row says "completed" while nothing has
      # been posted — and that window can end in a rollback (blank/invalid text
      # restores the task to `delegated`) or never end at all (the worker dies).
      # A concurrent reply landing in it holds the only copy of the answer, so it
      # must surface. Status alone cannot tell this from the case above; the
      # linked reply comment can.
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
      CONFLICT_CLAIMED_WITHOUT_REPLY = "claimed_without_reply"
      CONFLICT_NOT_DELEGATED = "not_delegated"

      # Every winning claim passes through claimed-without-reply on its way to
      # answered: the status flips first and the link lands one comment save
      # later. Deciding on the first read would therefore report the ordinary
      # sibling race as a lost reply purely on timing. Waiting does not weaken
      # the proof — only an actually linked comment is ever called benign — it
      # just gives finalization the moment it needs to produce one. Past the
      # deadline the answer is the same as before: surface it.
      FINALIZE_GRACE_SECONDS = 0.5
      FINALIZE_GRACE_INTERVAL = 0.05

      def conflict_reason(agent:, topic:, requested_task_id:)
        task = Task.find_by(id: requested_task_id, agent_id: agent.id, topic_id: topic.id)
        return CONFLICT_NOT_DELEGATED unless task&.status == "done"

        # `reply_comment` is what #finalize links (comment.task_id = task.id), so
        # its presence is the only proof the dispatch was actually answered.
        await_reply_link(task) ? CONFLICT_ALREADY_COMPLETED : CONFLICT_CLAIMED_WITHOUT_REPLY
      end

      # Post-claim side effects, run only after the reply comment is saved. Links
      # the comment to the claimed task, releases the ResourceTracker slot the
      # AiAgentJob held under task.id, and drains the topic queue — mirroring AiAgentJob#perform's success path for
      # non-delegated runs.
      def finalize(agent:, task:, comment:)
        comment.update_column(:task_id, task.id)

        Orchestration::ResourceTracker.for(agent).release!(task.id)

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

      # Poll for the link #finalize creates, up to FINALIZE_GRACE_SECONDS.
      # Monotonic clock so a wall-clock adjustment cannot stretch or collapse
      # the deadline mid-wait.
      def await_reply_link(task)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FINALIZE_GRACE_SECONDS
        loop do
          return true if reply_linked?(task)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep FINALIZE_GRACE_INTERVAL
        end
      end

      # uncached because the point of asking twice is to see a write another
      # request committed after the first ask. Rails wraps each request in
      # QueryCache, which would otherwise serve the identical SELECT from the
      # first (empty) result for the whole wait.
      def reply_linked?(task)
        Comment.uncached { Comment.exists?(task_id: task.id) }
      end

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
