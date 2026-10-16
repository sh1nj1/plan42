module Collavre
  class AiAgentJob < ApplicationJob
    queue_as :ai_agents
    include DispatchAdmission

    # Allow resuming a task that was pending approval
    def perform(agent_id_or_task, event_name = nil, context = nil, replay_identity = nil)
      return if Orchestration::ExecutionFence.retired?(job_id)

      agent_id_or_task = Orchestration::TaskResumer.reclaimed_task(job_id) || agent_id_or_task
      if agent_id_or_task.is_a?(Task)
        # Resume existing task
        task = agent_id_or_task
        if task.reload.status == "cancelled"
          # A cancelled task can still be holding the topic slot. Promotion moves
          # a waiter queued -> pending and enqueues this job, and the whole gap
          # from that claim until this line is one where deleting the comment it
          # answers cancels it (Comment#cancel_pending_tasks covers `pending`).
          # Returning bare hands the slot to nobody, so the waiters behind it sit
          # queued until orphan recovery. Same reason the fold's own cancelled
          # branch below drains — this is the earlier door onto it.
          if task.trigger_event_payload&.key?("topic")
            Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          end
          return
        end

        agent = task.agent
        return unless admit_keep_resumption(task) { Workflow::TaskAdmission.validate_start!(task) }

        # Guard: same offline-session check as the agent_id branch below.
        # Queued Claude Channel tasks resumed via Orchestration::AgentOrchestrator
        # .dequeue_next_for_topic enter this branch as AiAgentJob.perform_later(task).
        # If AgentChannel#unsubscribed removed the last presence row while the
        # task was queued (WS drop without DELETE /agent/:id, e.g. SIGKILL or
        # network blip past the reconnect grace), and another completion later
        # drains the queue, this task would otherwise be promoted to running →
        # delegated and broadcast to a clientless agent:user:<id> stream —
        # held until stuck recovery.
        return if reject_offline_resumption?(task, agent)

        # A claimed task holds the topic slot as `pending` from promotion until
        # this line, and a comment arriving in that window parks a waiter that
        # enqueue-time coalescing cannot fold into a non-`queued` sibling. Both
        # turns are still un-started here, so this is the last place the fold
        # can happen — and it must run before the assignment guard below, which
        # reads the payload this may re-anchor.
        Orchestration::AgentOrchestrator.coalesce_at_start!(task)
        if task.reload.status == "cancelled"
          # The fold's re-anchor found no comment left to answer. A `pending`
          # task holds no ResourceTracker reservation yet (reserve! is below),
          # but it does hold the topic slot — drain or the queue stalls.
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          return
        end

        # Guard: an exclusive primary-agent assignment can also land after a task
        # has already been cleared for execution, so checking at enqueue time is
        # not sufficient. AgentOrchestrator.dequeue_next_for_topic revalidates and
        # then enqueues asynchronously — a pin created in that window is missed —
        # and approval resumption (Comments::ActionExecutor) re-enqueues a
        # pending_approval task with no check at all, after a pause that can last
        # as long as the human takes to approve. Re-check at the moment of
        # execution so a demoted agent cannot answer in a topic that is now
        # exclusively someone else's.
        unless Orchestration::Matcher.prepare_waiting_task!(task)
          Rails.logger.info(
            "[AiAgentJob] Cancelling resumed task #{task.id}: topic #{task.topic_id} " \
            "no longer permits the recorded agent (agent=#{agent.id})"
          )
          reject_assignment_resumption(task, agent)
          return
        end

        return unless admit_keep_resumption(task) { Workflow::TaskAdmission.start!(task, execution_job_id: job_id) }
      else
        agent = User.find(agent_id_or_task)
        task = admit_new_dispatch(agent, event_name, context, replay_identity)
        return task unless task.is_a?(Task)
      end

      # This attempt's generation. If the turn is suspended and resumed while
      # this worker is still unwinding, the resumed attempt owns the row.
      attempt_generation = Orchestration::ExecutionFence.generation(task)

      # Reserve resources before starting work
      tracker = Orchestration::ResourceTracker.for(agent)
      # Reserve under the stable task.id, not the per-run job_id: a task can
      # outlive the job that reserved its slot (Claude Channel tasks wait on an
      # MCP reply, pending_approval tasks pause on ApprovalPendingError), and
      # every external release path — TasksController#cancel, stuck recovery,
      # agent teardown — releases! by task.id. A job_id key would leave those
      # releases unmatched, leaking the slot until the cache expiry.
      is_claude_channel_agent = agent.claude_channel_agent?
      resource_id = task.id
      tracker.reserve!(resource_id)
      should_release = true

      begin
        service = AiAgentService.new(task)
        return if is_claude_channel_agent && !hand_to_channel!(service, task, attempt_generation)

        return unless Workflow::FixedAnchor.validate!(task)
        service.call

        # Claude Channel agents delegate via MCP; no immediate response expected
        if is_claude_channel_agent
          # Hold agent capacity until reply / cancel / stuck-recovery releases it.
          should_release = false
        else
          transition_running_task!(task, attempt_generation, status: "done")
        end
      rescue ApprovalPendingError
        # Task status already set to pending_approval by AiAgentService
        # Don't release resources yet - task will resume
        should_release = false
        Rails.logger.info("AiAgentJob paused for task #{task.id}: awaiting tool approval")
      rescue TurnDeadlineError
        # AgentLifecycleManager already wrote the terminal status inside this
        # call stack. Restore/settle of dropped dispatches needs nothing extra:
        # fail_while_worker_settles! marked the row, and the ensure below
        # settles it.
        Rails.logger.info("AiAgentJob turn deadline exceeded for task #{task.id}")
      rescue CancelledError
        # Task status already set to "cancelled" by Comment callback
        Rails.logger.info("AiAgentJob cancelled for task #{task.id}: trigger message deleted")
        # Where a turn stopped mid-answer settles. The cancel was committed in
        # another process while this worker was inside the provider call, so
        # Task's status callback declined to decide
        # (Task#ended_while_worker_settles?) and this is the first moment either
        # answer exists: AiAgentService's ensure has recorded whether the
        # payload got there on the way up to here.
        # Reloaded because the status was written to the row by somebody else.
        Orchestration::DeliveryRecord.restore_if_undelivered!(task.reload)
      rescue StandardError => e
        fail_turn!(task, e)
      ensure
        # Guarantee resource release for all paths except pending_approval
        settle_attempt!(task, attempt_generation, (tracker if should_release))
      end
    end

    private

    # Screened while still running, so an unanswered screening can pause the
    # turn for approval before anything is handed to the session.
    #
    # For Claude Channel agents, transition to "delegated" BEFORE dispatching.
    # The MCP client can receive the broadcast and POST /reply on a different
    # thread before AiAgentService#call returns; the reply handler only looks
    # for status: "delegated" tasks, so a late update! would leave the
    # already-answered task stuck in delegated until stuck recovery.
    #
    # Atomic running -> delegated transition. If AgentsController#destroy
    # races us between reserve! and this line and flips the task to
    # "cancelled", the locked status check fails, we skip dispatch, and the
    # caller's ensure block releases the slot. A separate reload + update!
    # would let the cancel slip in between.
    def hand_to_channel!(service, task, attempt_generation)
      service.screen_channel_turn!
      return true if delegate_to_channel!(task, attempt_generation)

      Rails.logger.info(
        "[AiAgentJob] Claude Channel task #{task.id} not in running state " \
        "(status=#{task.status}); skipping dispatch"
      )
      false
    end

    # Give back what the attempt held once its worker is out — unless the turn
    # was suspended and resumed under it: the resumed attempt now owns the
    # task-keyed reservation, the row's settling and the drain when it ends.
    def settle_attempt!(task, attempt_generation, tracker)
      settled_task = Task.find_by(id: task.id)
      return if settled_task && Orchestration::ExecutionFence.superseded?(settled_task, attempt_generation)

      tracker&.release!(task.id, tokens_used: 0)
      return unless settled_task

      if Orchestration::DeliveryRecord.worker_settling?(settled_task.trigger_event_payload)
        # StuckDetector failed this row while this worker was still in the
        # provider call. The worker is out now, so remove the deferral and ask
        # the restore question from the handoff evidence AiAgentService wrote.
        Orchestration::DeliveryRecord.settle_worker!(settled_task)
        Orchestration::DeliveryRecord.restore_if_undelivered!(settled_task.reload)
      end
      return unless settled_task.trigger_event_payload&.key?("topic") &&
                    %w[done failed cancelled escalated].include?(settled_task.status)

      Orchestration::AgentOrchestrator.dequeue_next_for_topic(settled_task.topic_id, settled_task.creative_id)
    end

    def fail_turn!(task, error)
      # Orchestration::TaskResumer already suspended the task and handed back
      # its slot; it will be resumed as the same row. Writing `failed` here
      # would end a turn that is only paused.
      if error.is_a?(TaskSuspendedError)
        return Rails.logger.info("AiAgentJob suspended for task #{task.id} (reason=#{task.reload.suspend_reason})")
      end

      task.update!(status: "failed")
      Rails.logger.error("AiAgentJob failed for task #{task.id}: #{error.message}")
      raise error
    end

    # The offline session is expected back (reconnect grace, a restarted
    # client), so the turn is suspended rather than cancelled: the reconnect
    # resumes it as the same row. A session topic's turn waits for that session
    # specifically — another live session of the agent does not answer it.
    def reject_offline_resumption?(task, agent)
      return false if Orchestration::TaskResumer.claude_channel_reachable?(agent, task)
      Rails.logger.info(
        "[AiAgentJob] Suspending resumed Claude Channel task #{task.id}: " \
        "session offline (no live presence)"
      )
      if task.workflow?
        Workflow::TaskAdmission.reject_resumption!(task)
      elsif !Orchestration::TaskResumer.suspend!(task, reason: "agent_offline")
        # Not suspendable — an approval-paused turn waits on a person, so it
        # ends as before rather than resume past its approval.
        task.cancel_if_active!
        if task.trigger_event_payload&.key?("topic")
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
        end
      end
      true
    end

    def reject_assignment_resumption(task, agent)
      return Workflow::TaskAdmission.reject_resumption!(task) if task.workflow?
      task.cancel_if_active!
      # Approval-paused work holds its reservation without a worker ensure block.
      Orchestration::ResourceTracker.for(agent).release!(task.id)
      Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
    end

    # A terminal status can be written by Stop/StuckDetector after the service's
    # last lifecycle checkpoint but before this job records its outcome. Lock
    # and re-check the row so normal completion/retry cannot overwrite that
    # external winner.
    def transition_running_task!(task, attempt_generation, **attributes)
      task.with_lock do
        raise TaskSuspendedError if Orchestration::ExecutionFence.superseded?(task, attempt_generation)
        raise CancelledError unless task.status == "running"

        task.update!(attributes)
      end
    end

    # Create this dispatch's Task row, either admitted (`running`) or parked as
    # a `queued` waiter when the topic's concurrency slot is already taken.
    #
    # Returns the admitted task, or nil when the dispatch was deferred.
    def dispatch_attributes(agent, event_name, context)
      {
        name: "Response to #{event_name}",
        trigger_event_name: event_name,
        trigger_event_payload: context,
        agent: agent,
        topic_id: context&.dig("topic", "id"),
        creative_id: context&.dig("creative", "id")
      }
      .merge(Workflow::TaskAdmission.attributes(context, agent))
    end

    # The handoff marker is written with the status so recovery never sees a
    # delegated row without it. Columns only, as the update_all this replaced:
    # the Channel reply path owns what happens once the row is delegated.
    def delegate_to_channel!(task, attempt_generation)
      task.with_lock do
        next false unless task.status == "running"
        next false if Orchestration::ExecutionFence.superseded?(task, attempt_generation)

        task.update_columns(
          status: "delegated",
          trigger_event_payload: Orchestration::ExecutionFence.pending_handoff(task.trigger_event_payload),
          updated_at: Time.current
        )
        true
      end
    end

    # An admitted row starts executing under this job, so it carries the
    # ExecutionFence stamp from creation; a parked waiter is stamped when it is
    # promoted and started (Workflow::TaskAdmission.start!).
    def running_attributes(attrs)
      attrs.merge(
        status: "running",
        trigger_event_payload: Orchestration::ExecutionFence.stamp(attrs[:trigger_event_payload], job_id: job_id)
      )
    end

    def admit_or_defer!(agent, event_name, context)
      attrs = dispatch_attributes(agent, event_name, context)
      unless topic_admission_scoped?(context)
        return Task.create!(running_attributes(attrs)).tap { record_loop_breaker_turn(agent, context) }
      end

      task, admitted, current_context = nil, false, false
      # A queued row here is a waiter, and what speaks for it is settled now, with
      # the row, before the notice is posted below. Keep admission may wrap
      # both operations in its creative transaction. Persisting the opt-out on
      # the row keeps shared notice deletion from cancelling a deferred turn
      # even when no notice is visible yet.
      # Counting occupants and claiming the slot must be ONE step. Two workers
      # starting within the same millisecond — the exact burst this job defends
      # against — otherwise both read an occupancy below the limit before either
      # inserts its `running` row, and the re-check reproduces the very TOCTOU
      # race it exists to close. Serialize admission on the topic row: every
      # admission for a topic takes the same lock, so the loser reads the
      # winner's committed row.
      Task.transaction do
        next unless Orchestration::TopicSlot.lock_matches_context?(attrs[:topic_id], attrs[:creative_id])

        next unless Workflow::TaskAdmission.permitted?(context, agent)
        current_context = true
        admitted = Orchestration::TopicSlot.available_for?(agent.id, attrs[:topic_id], attrs[:creative_id], context)
        task = Task.create!((admitted ? running_attributes(attrs) : attrs).merge(
          status: admitted ? "running" : "queued",
          # Left nil on an admitted row: it is not waiting, so no notice speaks
          # for it and there is nothing for a stop control to represent.
          waiting_notice_scope: admitted ? nil : waiter_notice_scope(agent, context)
        ))
      end
      return unless current_context

      park_deferred_waiter(task, agent, event_name, context, attrs[:topic_id], attrs[:creative_id]) unless admitted
      # Count where the row is created, before an admitted turn starts and after
      # a deferred turn is parked. A stale context creates no row and no count.
      record_loop_breaker_turn(agent, context)
      task if admitted
    end

    # Record a created turn for the loop breaker's creative-retry count.
    # User-initiated messages are not loop material — a person typing twice is
    # not a runaway — and LoopBreaker skips those itself.
    def record_loop_breaker_turn(agent, context)
      creative_id = context&.dig("creative", "id")
      return unless creative_id

      Orchestration::LoopBreaker.new(context).record_task(
        creative_id, agent.id,
        topic_id: context&.dig("topic", "id"),
        triggered_by_user: context&.dig("comment", "from_ai") != true
      )
    end

    # Which notice will speak for a waiter parked by this dispatch: the topic's
    # shared one when this agent coalesces, its own per-deferral one when it has
    # opted out. Resolved once, at the moment the waiter is created, so the fold,
    # the notice and the shared notice's stop button all read one answer.
    def waiter_notice_scope(agent, context)
      if Orchestration::PolicyResolver.new(context).coalesce_pending_tasks_for?(agent)
        Comment::WAITING_NOTICE_TOPIC
      else
        Comment::WAITING_NOTICE_TASK
      end
    end

    # Is this dispatch subject to the topic concurrency limit at all?
    # Topic-less dispatches are not.
    def topic_admission_scoped?(context)
      context.is_a?(Hash) && context.key?("topic")
    end

    # Finish parking a waiter created by #admit_or_defer!: fold it together with
    # any waiters already parked for the same agent/topic/creative, and surface
    # one "⏳" notice for the topic.
    def park_deferred_waiter(waiter, agent, event_name, context, topic_id, creative_id)
      # Read off the waiter rather than resolved again: folding and the notice are
      # the same policy answer, and asking twice is how they come to disagree
      # about a wait whose policy changed in between.
      if waiter.waiting_notice_scope == Comment::WAITING_NOTICE_TOPIC
        Orchestration::TaskCoalescer.coalesce!(waiter)
      end
      Orchestration::WaitingNoticeManager.post_topic_concurrency_notice(
        creative_id, topic_id, context, agent: agent, waiter: waiter
      )

      Rails.logger.info(
        "[AiAgentJob] Deferred agent #{agent.id} into topic #{topic_id} queue as task " \
        "#{waiter.id}: slot already occupied (event=#{event_name})"
      )

      # A holder may have finished between the admission check and this point,
      # leaving a waiter with nobody left to drain it (its
      # dequeue_next_for_topic already ran). Drain unconditionally: this
      # deferral is not proof the topic is full — with topic_max > 1 an agent
      # defers because *it* is busy while a slot sits free for someone else, and
      # gating on "no occupants at all" would strand that waiter until the
      # unrelated holder finishes. dequeue_next_for_topic re-checks capacity and
      # eligibility under the admission lock, so an over-eager call is a no-op.
      ActiveRecord.after_all_transactions_commit do
        Orchestration::AgentOrchestrator.dequeue_next_for_topic(topic_id, creative_id)
      end

      nil
    end
  end
end
