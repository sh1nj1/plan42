module Collavre
  class AiAgentJob < ApplicationJob
    queue_as :ai_agents

    # Allow resuming a task that was pending approval
    def perform(agent_id_or_task, event_name = nil, context = nil)
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

        # Guard: same offline-session check as the agent_id branch below.
        # Queued Claude Channel tasks resumed via Orchestration::AgentOrchestrator
        # .dequeue_next_for_topic enter this branch as AiAgentJob.perform_later(task).
        # If AgentChannel#unsubscribed cleared routing_expression while the
        # task was queued (WS drop without DELETE /agent/:id, e.g. SIGKILL or
        # network blip past the reconnect grace), and another completion later
        # drains the queue, this task would otherwise be promoted to running →
        # delegated and broadcast to a clientless agent:user:<id> stream —
        # held until stuck recovery.
        if agent.claude_channel_agent? && agent.routing_expression.blank?
          Rails.logger.info(
            "[AiAgentJob] Skipping resumed Claude Channel task #{task.id}: " \
            "session offline (routing_expression blank)"
          )
          task.update!(status: "cancelled")
          if task.trigger_event_payload&.key?("topic")
            Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          end
          return
        end

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
        resumed_context = task.trigger_event_payload
        if resumed_context&.key?("topic") &&
           !Orchestration::Matcher.permits_assignment?(resumed_context, agent)
          Rails.logger.info(
            "[AiAgentJob] Cancelling resumed task #{task.id}: topic #{task.topic_id} " \
            "is now assigned to another agent (agent=#{agent.id})"
          )
          task.update!(status: "cancelled")
          # A pending_approval task kept its slot across the pause (the
          # ApprovalPendingError rescue sets should_release = false), and this
          # early return skips the ensure block that would give it back, so
          # release explicitly. release! is idempotent, so a queued task that
          # never reserved one is unaffected.
          Orchestration::ResourceTracker.for(agent).release!(task.id)
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
          return
        end

        task.update!(status: "running")
      else
        # Create new task
        agent = User.find(agent_id_or_task)

        # Guard: skip if the Claude Channel session has unregistered (or its WS
        # dropped) during the window between Scheduler enqueue and this job
        # firing. AgentsController#destroy / AgentChannel#unsubscribed clear
        # routing_expression on the per-session ai_user, so a blank value here
        # means there is no live MCP client to receive the dispatch. Without
        # this guard, a :delayed (busy / rate-limited) enqueue from
        # Scheduler#evaluate would materialize a fresh Task, flip it to
        # "delegated", and broadcast to a clientless agent:user:<id> stream
        # — holding the topic/agent slot until stuck recovery.
        if agent.claude_channel_agent? && agent.routing_expression.blank?
          Rails.logger.info(
            "[AiAgentJob] Skipping Claude Channel job for agent #{agent.id}: " \
            "session offline (routing_expression blank, event=#{event_name})"
          )
          return
        end

        # Guard: an exclusive primary-agent assignment created (or moved) after
        # this dispatch was scheduled must still bind it. A :delayed decision
        # (agent busy / rate limited) sits in the job queue with its agent already
        # chosen and is never re-matched, so without this a demoted agent speaks
        # in a topic that now belongs to someone else. Unlike a queued waiter
        # there is no Task yet to cancel, so cancelling on assignment change
        # cannot cover this path — the check has to happen here.
        if context && !Orchestration::Matcher.new(context).assignment_permits?(agent)
          Rails.logger.info(
            "[AiAgentJob] Skipping job for agent #{agent.id}: topic " \
            "#{context.dig('topic', 'id')} is now assigned to another agent " \
            "(event=#{event_name})"
          )
          return
        end

        # Guard: skip if there's already a running task for the same agent + comment
        comment_id = context&.dig("comment", "id")
        if comment_id && Task.duplicate_running_for_comment?(agent.id, comment_id)
          Rails.logger.warn(
            "[AiAgentJob] Skipping duplicate: agent #{agent.id} already has a running task " \
            "for comment #{comment_id} (event=#{event_name})"
          )
          return
        end

        # Guard: the same question the orchestrator asks before enqueueing, asked
        # again where the answer is authoritative. This job can sit in the queue
        # while the covering turn assembles its payload, so a dispatch that was
        # not droppable at enqueue time can be droppable by the time it runs —
        # and the enqueue door alone would leave that window open.
        #
        # As at the enqueue door, the drop only happens if the covering turn
        # records it — otherwise this dispatch has nobody to restore it.
        covering = Orchestration::DeliveryRecord.covering_task(agent, comment_id, context, event_name)
        if covering && Orchestration::DeliveryRecord.claim_drop!(covering, comment_id)
          Rails.logger.info(
            "[AiAgentJob] Skipping dispatch: comment #{comment_id} was already delivered to " \
            "agent #{agent.id} by in-flight task #{covering.id} (event=#{event_name})"
          )
          return
        end

        # Guard: the Scheduler's topic-concurrency check counts Task rows, but
        # the row for an :immediate decision is only created *here*. A burst of
        # comments dispatched before the first job runs therefore all see an
        # empty topic and are all judged :immediate — several turns run at once
        # in a topic limited to one. Re-check at the moment the row is created,
        # where the answer is authoritative, and defer into the queue instead.
        task = admit_or_defer!(agent, event_name, context)

        # Counted where the row is created, not where the turn starts — and so
        # before the deferral returns. Losing the admission race does not make
        # this a different turn: the same dispatch, from the same burst, is
        # parked instead of admitted, and the promotion that later runs it
        # enters the resumed-Task branch above, which records nothing either. A
        # count taken only on the winning side of a race is exactly blind to the
        # bursts the threshold exists to catch.
        record_loop_breaker_turn(agent, context)
        return if task.nil?
      end

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

        AiAgentService.new(task).call

        # Claude Channel agents delegate via MCP; no immediate response expected
        if is_claude_channel_agent
          # Hold agent capacity until reply / cancel / stuck-recovery releases it.
          should_release = false
        else
          transition_running_task!(task, status: "done")
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
        task.update!(status: "failed")
        Rails.logger.error("AiAgentJob failed for task #{task.id}: #{e.message}")
        raise e
      ensure
        # Guarantee resource release for all paths except pending_approval
        tracker.release!(resource_id, tokens_used: 0) if should_release && tracker && resource_id
        settled_task = task&.reload
        if settled_task &&
           Orchestration::DeliveryRecord.worker_settling?(settled_task.trigger_event_payload)
          # StuckDetector failed this row while this worker was still in the
          # provider call. The worker is out now, so remove the deferral and ask
          # the restore question from the handoff evidence AiAgentService wrote.
          Orchestration::DeliveryRecord.settle_worker!(settled_task)
          Orchestration::DeliveryRecord.restore_if_undelivered!(settled_task.reload)
        end
        if settled_task&.trigger_event_payload&.key?("topic") &&
           %w[done failed cancelled escalated].include?(settled_task.status)
          Orchestration::AgentOrchestrator.dequeue_next_for_topic(settled_task.topic_id, settled_task.creative_id)
        end
      end
    end

    private

    # A terminal status can be written by Stop/StuckDetector after the service's
    # last lifecycle checkpoint but before this job records its outcome. Lock
    # and re-check the row so normal completion/retry cannot overwrite that
    # external winner.
    def transition_running_task!(task, **attributes)
      task.with_lock do
        raise CancelledError unless task.status == "running"

        task.update!(attributes)
      end
    end

    # Create this dispatch's Task row, either admitted (`running`) or parked as
    # a `queued` waiter when the topic's concurrency slot is already taken.
    #
    # Returns the admitted task, or nil when the dispatch was deferred.
    def admit_or_defer!(agent, event_name, context)
      attrs = {
        name: "Response to #{event_name}",
        trigger_event_name: event_name,
        trigger_event_payload: context,
        agent: agent,
        topic_id: context&.dig("topic", "id"),
        creative_id: context&.dig("creative", "id")
      }
      return Task.create!(attrs.merge(status: "running")) unless topic_admission_scoped?(context)

      topic_id = context.dig("topic", "id")
      creative_id = context.dig("creative", "id")
      admitted = false
      task = nil
      # A queued row here is a waiter, and what speaks for it is settled now, with
      # the row — not later, from whichever notices happen to be visible. Its
      # notice is posted in a separate transaction below, so between the two this
      # waiter is queued with nothing naming it, and a shared notice deleted in
      # that window would read an opted-out waiter as one of its own and cancel a
      # turn that was only deferred.
      notice_scope = waiter_notice_scope(agent, context)

      # Counting occupants and claiming the slot must be ONE step. Two workers
      # starting within the same millisecond — the exact burst this job defends
      # against — otherwise both read an occupancy below the limit before either
      # inserts its `running` row, and the re-check reproduces the very TOCTOU
      # race it exists to close. Serialize admission on the topic row: every
      # admission for a topic takes the same lock, so the loser reads the
      # winner's committed row.
      Task.transaction do
        Orchestration::TopicSlot.lock!(topic_id, creative_id)
        admitted = Orchestration::TopicSlot.available_for?(agent.id, topic_id, creative_id, context)
        task = Task.create!(attrs.merge(
          status: admitted ? "running" : "queued",
          # Left nil on an admitted row: it is not waiting, so no notice speaks
          # for it and there is nothing for a stop control to represent.
          waiting_notice_scope: admitted ? nil : notice_scope
        ))
      end

      return task if admitted

      park_deferred_waiter(task, agent, event_name, context, topic_id, creative_id)
      nil
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

    # Is this dispatch subject to the topic concurrency limit at all? Workflow
    # subtasks and other topic-less dispatches are not.
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
      Orchestration::AgentOrchestrator.post_topic_concurrency_notice(
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
      Orchestration::AgentOrchestrator.dequeue_next_for_topic(topic_id, creative_id)

      nil
    end
  end
end
