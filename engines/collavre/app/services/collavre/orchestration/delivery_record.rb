# frozen_string_literal: true

module Collavre
  module Orchestration
    # What a turn actually handed its agent, written down at the moment it was
    # handed over.
    #
    # A burst of external events (a PR comment sync, a webhook batch) creates
    # several comments in one topic within milliseconds.
    # Orchestration::TaskCoalescer folds the *un-started* tasks of that burst
    # together, but it cannot help the comment that arrives while a turn is
    # already running: that dispatch parks a waiter, and the agent speaks a
    # second time when the waiter is promoted.
    #
    # For a non-session agent the second turn is usually redundant.
    # AiAgent::MessageBuilder#append_chat_history reads the topic's comments at
    # *execution* time, so a comment committed before the payload was assembled
    # is already inside the running turn's context — the agent has read it.
    #
    # For a session-backed agent it is not redundant at all:
    # AiAgent::SessionContextResolver#incremental_payload keeps only the
    # :trigger message, so the running turn never carried that text. Dropping
    # the dispatch there would be message loss rather than de-duplication, and
    # coalescing (merge into "merged_comment_ids") stays the right answer.
    #
    # So "the agent is busy" is the wrong predicate and "the agent has already
    # been given that comment" is the right one — and the only place that can
    # answer it is the resolved payload itself. This module records the answer
    # off that payload and is the single door every reader goes through.
    module DeliveryRecord
      # Comment ids a turn delivered as chat history although it was not created
      # for them. Sits beside TaskCoalescer::PAYLOAD_KEY and
      # TaskCoalescer::ACQUIRED_ANCHOR_KEY, which record the other two ways a
      # turn ends up carrying a comment it was not dispatched for.
      KEY = "history_delivered_comment_ids"

      # Comment ids whose dispatch this turn actually refused.
      #
      # A strict subset of KEY, and the distinction matters because the two are
      # read for opposite purposes. KEY answers "has the agent been given this
      # comment?", and chat history is the whole topic — Matcher's exclusive
      # routings do not filter it, so every agent in a topic reads every public
      # comment in it, including ones addressed to somebody else. That is the
      # right predicate for the drop, which is only ever asked downstream of
      # Matcher about a dispatch that already exists.
      #
      # It is the wrong predicate for the restore, whose subject is dispatches
      # and which creates one per id it decides on. Reading KEY there turns a
      # comment routed past this agent into a turn for it, past Matcher
      # entirely; and it reads a dispatch still sitting in the job queue — an
      # :immediate decision's Task row is created only when its job runs — as a
      # discarded one, putting a second turn on a comment that already has one.
      # Neither is visible in the absence of a Task row, so the drop is written
      # down instead of reconstructed.
      DROPPED_KEY = "dropped_dispatch_comment_ids"

      # This turn asked the provider for an answer and the request never got
      # there.
      #
      # Every other reader here decides off the turn's *status*, which works
      # while the endings line up with what was delivered. This one does not:
      # AiClient#chat catches the provider error, streams "⚠️ AI Error" into
      # the reply and returns nil, and AiAgentJob marks an ordinary task `done`
      # on that — the single status every reader counts as delivery. So a turn
      # can end in the delivered ending having handed over nothing at all, and
      # the comments it discarded were read by nobody.
      #
      # Recorded rather than inferred, because nothing else in the row says it:
      # `done` with an error in the reply text looks exactly like `done`. The
      # only place that knows is the service holding the client that failed.
      HANDOFF_FAILED_KEY = "handoff_failed"

      # This turn did hand its payload to the provider — the same question,
      # asked positively, for the endings that never reach the line above.
      #
      # HANDOFF_FAILED_KEY is written after #chat returns, so a turn that leaves
      # by exception never records anything: a user pressing Stop mid-answer
      # ends `cancelled`, which every reader counts as undelivered outright,
      # although the provider has the payload by then and AgentLifecycleManager
      # keeps the partial reply. The comments that turn swallowed were read
      # along with it, so restoring them starts fresh work the moment the user
      # asked for none, and answers them twice.
      #
      # Positive rather than a second failure flag, because the absence of the
      # record has to keep meaning "restore": most cancellations and every hard
      # crash write nothing at all, and losing a comment costs more than a
      # redundant turn. Only a turn that got far enough to say so is exempt.
      HANDED_OFF_KEY = "handed_off"

      # The comment ids an attempt that handed off actually carried.
      #
      # HANDED_OFF_KEY answers for the *turn*, and that is enough while a turn
      # is one attempt. It is not: a tool approval pauses the turn and
      # Comments::ActionExecutor resumes the same Task row, so AiAgentService
      # runs over it again with a fresh client. The first pass reached its tools,
      # which means the provider had that payload; if the resumed request then
      # never lands, the row carries both records, Task#ended_undelivered? reads
      # the failure first, and the restore puts back every dispatch ever dropped
      # against the turn — including the ones the first pass handed over.
      #
      # So the exemption is recorded per comment, which is the subject the
      # restore actually has. KEY at the moment of the handoff is exactly what
      # went over: record! writes it before the request, and a drop taken later
      # against an id already in KEY was in that payload too. Accumulates across
      # attempts for the same reason KEY does — what one pass delivered it still
      # delivered — and a comment only the failed pass read is not in it, so it
      # is still owed back.
      HANDED_OFF_IDS_KEY = "handed_off_comment_ids"

      # Comments this turn's restore has already put back on their way.
      #
      # AiAgentJob creates the Task row when it *runs*, so between a restored
      # enqueue and its execution the comment has no row and reads as orphaned —
      # a worker outage or a backlog longer than the sweep interval therefore
      # had every pass enqueue another copy, and the copies that lose the
      # admission race become independent waiters that answer the comment again.
      # Eventual Task creation cannot be the idempotency marker for work that
      # has not started.
      #
      # Written before the enqueue and given back if the enqueue raises, so the
      # claim never outlives the dispatch it stands for: a comment claimed by an
      # enqueue that never happened is the previous finding pointing the other
      # way.
      RESTORED_KEY = "restored_dispatch_comment_ids"

      # Everything a turn writes onto its own payload while it runs, as opposed
      # to what it was dispatched with.
      #
      # One list rather than a strip enumerated at the point of use: a restored
      # dispatch is the one that was discarded, so it carries what a dispatch
      # carries and nothing the turn wrote onto itself afterwards. Enumerating
      # that at the call site is how HANDOFF_FAILED_KEY came to be left in — it
      # was added here long after restored_context had named the other four —
      # and the drift test on this constant is what will catch the sixth.
      TURN_SCOPED_KEYS = [
        KEY, DROPPED_KEY, HANDOFF_FAILED_KEY, HANDED_OFF_KEY, HANDED_OFF_IDS_KEY,
        RESTORED_KEY, TaskCoalescer::PAYLOAD_KEY, TaskCoalescer::ACQUIRED_ANCHOR_KEY
      ].freeze

      # Statuses in which a turn is still the thing that will answer.
      #
      # Narrower than AgentOrchestrator::DELIVERED_STATUSES, which also counts
      # `done`, and deliberately so: the two readers ask different questions.
      # The promotion door asks "may this *parked* waiter still speak?", and a
      # waiter that may not simply loses its turn — it had no independent claim
      # on the slot. This module's other reader is the dispatch door, where the
      # alternative to running is discarding the dispatch outright. A turn that
      # has already finished is no longer answering anything, so a comment
      # arriving after it gets its own turn rather than being silently dropped.
      #
      # `queued`/`pending` are excluded at both: nothing has been delivered yet.
      IN_FLIGHT_STATUSES = %w[running delegated pending_approval].freeze

      # Terminal statuses in which the turn delivered nothing after all.
      #
      # The complement of AgentOrchestrator::DELIVERED_STATUSES over the
      # terminal set, and that is the whole point: promotion says a dead turn
      # silences nothing by leaving these statuses out of its list, and a parked
      # waiter survives on that — it is still a row, and the refresh re-reads
      # the covering turn's status before deciding anything.
      #
      # A *dropped* dispatch has no row to re-read anything. So the drop owes
      # the same answer through the only means it has left: putting the
      # discarded dispatch back. Without it the two doors disagree about what a
      # failure means, and the disagreement costs a comment nobody answers.
      #
      # DeliveryRecordTest asserts this is exactly the complement; a status
      # added to one list and not the other is how they drift apart.
      UNDELIVERED_TERMINAL_STATUSES = %w[failed cancelled escalated].freeze

      # Statuses a row can be in and still owe a restore — the undelivered
      # endings, plus the one that reads as delivered until the payload is
      # consulted. Derived rather than listed so the sweep cannot come to scan
      # for less than Task#ended_undelivered? decides on.
      RESTORABLE_STATUSES = (UNDELIVERED_TERMINAL_STATUSES + %w[done]).freeze

      # How far back restore_missed! looks.
      #
      # Comfortably more than its schedule, so a restore the callback lost gets
      # several attempts, and finite because it is a backstop: a comment whose
      # turn ended an hour ago has been overtaken by whatever the topic did
      # since, and re-dispatching it then would be the more surprising answer.
      RESTORE_SWEEP_WINDOW = 1.hour

      # Slack added to the provider timeout when waiting for a stopped turn's
      # worker to settle — see .cancel_settle_grace.
      CANCEL_SETTLE_SLACK = 5.minutes

      # Record what `resolved` carries as chat history.
      #
      # Measured off the *resolved* payload — the messages the adapter is handed
      # — rather than off MessageBuilder's output, because the session filter
      # sits between the two and is exactly the distinction that decides whether
      # a comment was delivered at all. A future filter added there is then
      # accounted for without a second place having to learn about it.
      #
      # Restricted to ids above the turn's anchor. Chat history normally holds
      # the topic's backlog, which this turn did not swallow and must not
      # silence; a history comment *newer* than the anchor can only have landed
      # after this turn was dispatched, which is the burst case and the only one
      # this record is for. Ids rather than created_at: a burst is written by
      # several processes and the clock is whichever one wrote the row (the same
      # reason AiAgent::MergedTriggerComments orders by id).
      #
      # Accumulates. A resumed turn (pending_approval, or a retry) assembles a
      # second time, and what the first pass delivered it still delivered.
      #
      # Written onto the row's payload under the same lock as claim_drop!, not
      # onto the caller's. A resumed turn's task object is loaded before it
      # assembles, and a dispatch refused in the meantime writes DROPPED_KEY
      # into the same JSON column from another process; a merge onto the stale
      # copy would erase the drop, and a drop no restore can find is the
      # message lost. Both writers of this column now read it under the lock.
      def self.record!(task, resolved)
        return if task.nil?

        Task.transaction do
          row = Task.lock.find_by(id: task.id)
          payload = row&.trigger_event_payload
          next unless payload.is_a?(Hash)

          anchor_id = payload.dig("comment", "id").to_i
          next if anchor_id.zero?

          swallowed = history_comment_ids(resolved).select { |id| id > anchor_id }
          merged = (ids_in(payload) + swallowed).uniq.sort
          next if merged == ids_in(payload)

          row.update!(trigger_event_payload: payload.merge(KEY => merged))
          task.reload unless task.equal?(row)
        end
      end

      def self.ids_in(payload)
        return [] unless payload.is_a?(Hash)

        Array(payload[KEY]).compact.map(&:to_i)
      end

      # Write down that this turn's request never reached the provider.
      #
      # Under the same row lock as record! and claim_drop!, for the same
      # reason: a dispatch refused in another process writes DROPPED_KEY into
      # this JSON column while the turn runs, and a merge onto the caller's
      # copy would erase it.
      def self.mark_handoff_failed!(task)
        return if task.nil?

        Task.transaction do
          row = Task.lock.find_by(id: task.id)
          payload = row&.trigger_event_payload
          next unless payload.is_a?(Hash)
          next if handoff_failed?(payload)

          row.update!(trigger_event_payload: payload.merge(HANDOFF_FAILED_KEY => true))
          task.reload unless task.equal?(row)
        end
      end

      def self.handoff_failed?(payload)
        return false unless payload.is_a?(Hash)

        payload[HANDOFF_FAILED_KEY] == true
      end

      # Write down that this turn's payload did reach the provider.
      #
      # Under the same row lock and for the same reason as its two siblings: a
      # dispatch refused in another process writes DROPPED_KEY into this column
      # while the turn runs, and this is written as the turn is being torn down
      # by the very cancellation that dispatch is racing.
      def self.mark_handed_off!(task)
        return if task.nil?

        Task.transaction do
          row = Task.lock.find_by(id: task.id)
          payload = row&.trigger_event_payload
          next unless payload.is_a?(Hash)

          # Not `next if handed_off?`: a resumed attempt records the handoff a
          # second time, and what it carried this time is the point of asking.
          recorded = handed_off_ids_in(payload)
          covered = (recorded + ids_in(payload)).uniq.sort
          next if handed_off?(payload) && covered == recorded

          row.update!(trigger_event_payload: payload.merge(
            HANDED_OFF_KEY => true, HANDED_OFF_IDS_KEY => covered
          ))
          task.reload unless task.equal?(row)
        end
      end

      def self.handed_off?(payload)
        return false unless payload.is_a?(Hash)

        payload[HANDED_OFF_KEY] == true
      end

      def self.handed_off_ids_in(payload)
        return [] unless payload.is_a?(Hash)

        Array(payload[HANDED_OFF_IDS_KEY]).compact.map(&:to_i)
      end

      def self.restored_ids_in(payload)
        return [] unless payload.is_a?(Hash)

        Array(payload[RESTORED_KEY]).compact.map(&:to_i)
      end

      # Take responsibility for putting one dispatch back, or refuse it because
      # somebody already has.
      #
      # The same shape as claim_drop!, and for the same reason: the callback and
      # the sweep can be looking at this row at once, and the thing they would
      # both act on leaves no trace until a worker picks it up.
      #
      # @return [Boolean] whether the caller may enqueue the dispatch
      def self.claim_restore!(task, comment_id)
        id = comment_id.to_i
        return false if task.nil? || id.zero?

        claimed = false
        Task.transaction do
          row = Task.lock.find_by(id: task.id)
          payload = row&.trigger_event_payload
          next unless payload.is_a?(Hash)
          next if restored_ids_in(payload).include?(id)

          restored = (restored_ids_in(payload) + [ id ]).uniq.sort
          row.update!(trigger_event_payload: payload.merge(RESTORED_KEY => restored))
          claimed = true
        end
        claimed
      end

      # Give the claim back for a dispatch that was never enqueued after all.
      def self.release_restore_claim!(task, comment_id)
        id = comment_id.to_i
        return if task.nil? || id.zero?

        Task.transaction do
          row = Task.lock.find_by(id: task.id)
          payload = row&.trigger_event_payload
          next unless payload.is_a?(Hash)

          restored = restored_ids_in(payload) - [ id ]
          row.update!(trigger_event_payload: payload.merge(RESTORED_KEY => restored))
        end
      end

      def self.dropped_ids_in(payload)
        return [] unless payload.is_a?(Hash)

        Array(payload[DROPPED_KEY]).compact.map(&:to_i)
      end

      # Take responsibility for a dispatch about to be discarded, or refuse it.
      #
      # The drop and its record are one act, and this is where they are made
      # one. `covering_task` answers off the caller's snapshot; between that
      # answer and this write the turn can end, run its restore, and leave —
      # and a record written after that restore is a comment nobody ever comes
      # back for. So the status is re-read from the locked row, and a caller
      # told `false` dispatches normally instead of dropping. Refusing a sound
      # drop costs a redundant turn; taking an unsound one costs the message.
      #
      # @return [Boolean] whether the caller may discard the dispatch
      def self.claim_drop!(covering, comment_id)
        id = comment_id.to_i
        return false if covering.nil? || id.zero?

        claimed = false
        Task.transaction do
          task = Task.lock.find_by(id: covering.id)
          payload = task&.trigger_event_payload
          next unless task&.status.to_s.in?(IN_FLIGHT_STATUSES) && payload.is_a?(Hash)

          dropped = (dropped_ids_in(payload) + [ id ]).uniq.sort
          task.update!(trigger_event_payload: payload.merge(DROPPED_KEY => dropped))
          claimed = true
        end
        claimed
      end

      # The in-flight turn that has already given `comment_id` to `agent`, or nil.
      #
      # Every gate that drops a dispatch goes through this one method: the
      # orchestrator's enqueue door, AiAgentJob's late-admission door, and any
      # later one. Two doors that ask this question separately are how they come
      # to disagree about it.
      #
      # Scoped exactly like AgentOrchestrator.delivered_comment_ids — same agent,
      # topic, creative and trigger event — so a workflow subtask in another
      # creative, or a different event over the same comment, is a different
      # question and not an answer to this one.
      def self.covering_task(agent, comment_id, context, trigger_event_name)
        return nil if agent.nil? || comment_id.blank?
        return nil unless context.is_a?(Hash) && context.key?("topic")
        return nil unless PolicyResolver.new(context).drop_delivered_dispatches_for?(agent)
        # A review request is bound to the comment it quotes and can only run as
        # its own turn: AiAgentService and ReviewHandler read review behaviour
        # off the anchor, never off the history window. Having been read as
        # context is not having been answered, so a review is never dropped —
        # the same boundary TaskCoalescer and refresh_deferred_context! keep.
        return nil if Comment.review_message_ids([ comment_id ]).any?

        Task.where(
          agent_id: agent.id,
          topic_id: context.dig("topic", "id"),
          creative_id: context.dig("creative", "id"),
          trigger_event_name: trigger_event_name,
          status: IN_FLIGHT_STATUSES
        ).select(:id, :trigger_event_payload).find do |task|
          payload = task.trigger_event_payload
          # A turn still `running` after its request failed is not going to
          # answer anything, and dropping against it would record a drop after
          # the restore that ends it has already looked.
          next false if handoff_failed?(payload)

          ids_in(payload).include?(comment_id.to_i)
        end
      end

      # Put back the dispatches this turn's record caused to be discarded, now
      # that the turn has ended without delivering them.
      #
      # Driven off Task's status callback rather than from AiAgentJob's rescue:
      # the job is not the only door onto a failed turn — StuckDetector fails a
      # task that never reached a rescue at all — and a restore wired to one of
      # them is a restore that does not happen on the other.
      #
      # Its subject is DROPPED_KEY — the dispatches this turn refused — and not
      # KEY, which is merely everything it read. Only a refused dispatch is a
      # thing this turn owes back; see DROPPED_KEY for what taking the wider
      # set costs.
      #
      # Narrowed once more by what nothing else is on the hook for. A comment
      # swept into this turn's history may still have a waiter of its own
      # (parked before the turn assembled, so never droppable), and promotion
      # decides that waiter's fate by re-reading this turn's status. Restoring
      # it as well would put two turns on one comment. Belt to DROPPED_KEY's
      # braces: the record already excludes what was never dropped, and this
      # excludes what has since acquired a row of its own.
      #
      # And once more by HANDED_OFF_IDS_KEY, for the turn that ran more than
      # once: a comment an earlier attempt handed to the provider is not owed
      # back by a later attempt's failure.
      #
      # Each orphan is re-dispatched on its own, exactly as it would have been
      # had it never been dropped, and the ordinary admission path folds them
      # back together — rather than this method inventing a second merge rule
      # beside TaskCoalescer's.
      def self.restore!(task)
        # Re-read the row rather than trust the caller's copy. The drop record
        # is written by whichever dispatch was refused, in another process
        # entirely, onto a row this turn's own object was loaded before — so
        # the in-memory payload that reaches this callback is exactly the one
        # that predates every drop it is being asked about.
        payload = Task.find_by(id: task.id)&.trigger_event_payload
        return unless payload.is_a?(Hash) && payload.key?("topic")

        orphaned = dropped_ids_in(payload) - handed_off_ids_in(payload) -
                   claimed_comment_ids(task) - restored_ids_in(payload)
        return if orphaned.empty?

        agent = task.agent
        return if agent.nil?

        # Same eligibility the refresh applies when it moves an anchor: a
        # comment that was deleted, made private, or turned into an approval
        # action while the turn ran has nothing left to answer.
        Comment.public_only.without_approval_action
          .where(id: orphaned, topic_id: task.topic_id, creative_id: task.creative_id)
          .where.not(user_id: [ agent.id, nil ])
          .order(:id)
          .each do |comment|
          begin
            enqueue_restored(task, agent, task.trigger_event_name, restored_context(payload, comment))
          rescue StandardError => e
            # Each orphan is a dispatch of its own; one that cannot be enqueued
            # says nothing about the next. What it leaves behind is the absence
            # of a row, which is exactly what restore_missed! reads.
            Rails.logger.error(
              "[DeliveryRecord] Failed to restore dispatch for comment #{comment.id} " \
              "of task #{task.id}: #{e.class}: #{e.message}"
            )
          end
        end
      end

      # Ask again for every turn whose restore may not have been made.
      #
      # restore! runs from an after_update_commit callback, which is to say
      # after the covering turn's status is already committed: a transient
      # failure there has nothing left to roll back and no later transition that
      # would retry it, and the dropped dispatch is the one thing in this
      # feature with no row of its own to fall back on.
      #
      # Nothing extra is persisted for it, because the orphan set already is:
      # DROPPED_KEY is on the row and claimed_comment_ids subtracts whatever has
      # since acquired a Task, so a comment stays orphaned exactly until its
      # dispatch exists again and restore! is idempotent by construction. What
      # was lost is only the asking.
      #
      # A dispatch the Scheduler refuses leaves no row either, so it is asked
      # again on each pass through the window — which is the right answer for a
      # quota that has since reset, and a bounded number of cheap refusals if it
      # has not.
      # How long after a cancellation this sweep waits before deciding it.
      #
      # Task#stopped_mid_turn? explains why the status callback declines: Stop is
      # committed from another process while the worker is inside AiClient#chat,
      # and the worker's account of the handoff is written only on the way out.
      # This door reads a settled row, so it cannot ask that question — and it
      # cannot tell "still settling" from "nobody is coming" either. Without a
      # wait it answers in the callback's place and re-dispatches everything the
      # turn swallowed, minutes after the user asked for no more work.
      #
      # Derived from the configured provider timeout because that is what bounds
      # the wait in the shape this is for: Stop pressed while the turn is still
      # waiting for its first token, where AgentLifecycleManager#check_cancelled!
      # cannot fire at all because it polls from inside the streaming block.
      #
      # It is not a bound on a conversation that keeps making requests without
      # yielding content — a tool loop can outlast any grace, and for that one
      # this sweep can still be early. What that costs is a duplicate reply;
      # declining cancellations outright would cost the comment, and the
      # cancellers with no worker behind them at all — an agent unregistering,
      # an offline delegate, a worker killed before its own rescue — are exactly
      # what this sweep is here for.
      def self.cancel_settle_grace
        SystemSetting.llm_request_timeout_seconds.seconds + CANCEL_SETTLE_SLACK
      end

      def self.restore_missed!(window: RESTORE_SWEEP_WINDOW)
        grace = cancel_settle_grace

        [
          # The endings whose status is written after the worker is out of the
          # provider call, so the row is as settled as it will ever be.
          Task.where(status: RESTORABLE_STATUSES - [ "cancelled" ])
              .where(updated_at: window.ago..),
          # And the one that is not. The window moves with the wait rather than
          # being spent by it: subtracting the grace from a fixed horizon would
          # leave a cancellation less backstop than every other ending gets, and
          # at the default timeout almost none.
          Task.where(status: "cancelled")
              .where(updated_at: (window + grace).ago..grace.ago)
        ].each do |scope|
          scope.find_each { |task| restore_if_undelivered!(task) }
        end
      end

      # Ask the restore question of a turn that has settled.
      #
      # The one door for every caller that is not Task's status callback: this
      # sweep, and AiAgentJob's cancellation teardown, which is where a turn
      # stopped mid-answer settles — see Task#stopped_mid_turn? for why the
      # cancel itself cannot decide. Gated on the same predicate the callback is,
      # because a second door deciding "terminal" where the callback decides
      # Task#ended_undelivered? is how one of them comes to re-answer comments
      # the turn had already answered.
      #
      # Best effort, like the callback's: the teardown runs inside the job's last
      # rescue, where an escaping exception would turn a cancelled turn into a
      # failed job, and the sweep must not lose the rest of its pass to one row.
      # Nothing is lost by swallowing — the orphan set is on the row, so the next
      # pass asks again.
      def self.restore_if_undelivered!(task)
        return if task.nil? || !task.ended_undelivered?

        restore!(task)
      rescue StandardError => e
        Rails.logger.error(
          "[DeliveryRecord] Restore failed for task #{task.id}: #{e.class}: #{e.message} — " \
          "leaving it to the restore sweep"
        )
      end

      # Put the dispatch back the way the orchestrator would have, by asking the
      # same Scheduler again.
      #
      # The decision the drop discarded was a decision about *then*. A dispatch
      # refused while the agent was at its concurrency limit or rate-limited
      # carried a backoff with it, and enqueuing it now would run it past the
      # check that set that delay — while the dying turn's own ResourceTracker
      # slot is very often still held, since this fires from its status
      # callback. Replaying the delay recorded at drop time would be no better:
      # by now it describes pressure that may be long gone or much worse.
      #
      # Asked again, not merely honoured: a quota exhausted or a loop breaker
      # tripped between the drop and the restore refuses this dispatch exactly
      # as it would refuse a fresh one. AgentOrchestrator's own guard keeps
      # rejected work out of the record; this is the other end of the same
      # question, and only the scheduler can answer it as of now.
      #
      # Enqueued through AiAgentJob rather than AgentOrchestrator#enqueue_jobs
      # even for a :deferred decision, because the job door re-asks
      # Matcher#assignment_permits? against the re-anchored payload before it
      # parks anything — a restored dispatch has moved, and park_waiter would
      # create the row without that question being asked.
      def self.enqueue_restored(task, agent, event_name, context)
        # The one question no door on this path asks. Naming the agent skips
        # Matcher#match, and every routing path in #match is gated on feedback
        # permission for the creative; AiAgentJob re-asks the topic assignment
        # and nothing else. A permission revoked between the drop and the
        # restore would otherwise be seen by nobody, and this dispatch would
        # answer a creative the agent may no longer read.
        unless Matcher.permits_creative_access?(context, agent)
          Rails.logger.info(
            "[DeliveryRecord] Not restoring dispatch for comment #{context.dig("comment", "id")}: " \
            "agent #{agent.id} no longer has feedback permission on creative " \
            "#{context.dig("creative", "id")}"
          )
          return
        end

        decision = Scheduler.new(context).schedule([ agent ]).first
        return if decision.nil?

        comment_id = context.dig("comment", "id")
        case decision[:timing]
        when :rejected
          Rails.logger.info(
            "[DeliveryRecord] Not restoring dispatch for comment #{comment_id}: " \
            "scheduler rejected agent #{agent.id} (#{decision[:reason]})"
          )
        when :delayed
          enqueue_claimed(task, comment_id) do
            AiAgentJob.set(wait: decision[:delay]).perform_later(agent.id, event_name, context)
          end
        else
          enqueue_claimed(task, comment_id) { AiAgentJob.perform_later(agent.id, event_name, context) }
        end
      end
      private_class_method :enqueue_restored

      # Claim the comment, then enqueue — and only in that order. The job leaves
      # no row until a worker runs it, so between the two the comment reads as
      # orphaned to anyone else looking, and the sweep is looking every ten
      # minutes. A claim released on failure is the whole difference between
      # this and a dispatch nobody comes back for.
      def self.enqueue_claimed(task, comment_id)
        return unless claim_restore!(task, comment_id)

        begin
          yield
        rescue StandardError
          release_restore_claim!(task, comment_id)
          raise
        end
      end
      private_class_method :enqueue_claimed

      # The dispatch that was discarded — not a descendant of the turn that
      # discarded it. reanchor_payload is the single door for moving an anchor,
      # and TURN_SCOPED_KEYS is stripped after it because every one of them
      # describes the dead turn: its drop list would make a restored turn that
      # fails again restore the same comments a second time, its history record
      # would licence dropping them, its failed handoff would leave a turn that
      # succeeded unable to cover anything it read, its merged list would
      # re-send comments it was created for, and its acquired anchor would
      # label this turn's own trigger as borrowed.
      def self.restored_context(payload, comment)
        TaskCoalescer.reanchor_payload(payload, comment).except(*TURN_SCOPED_KEYS)
      end
      private_class_method :restored_context

      # Comment ids some other task in this turn's scope is already on the hook
      # for, as its trigger or as a merged block. Any status counts: what is
      # being asked is whether a dispatch exists at all, since the only thing
      # this restore undoes is a dispatch that was never allowed to become one.
      #
      # A terminal sibling counts too, and deliberately. For a comment to be in
      # DROPPED_KEY *and* have a row, the row came from a different dispatch of
      # the same comment — a redelivered event, which `duplicate_running_for_
      # comment?` lets past a merely queued waiter — so the discarded one is the
      # duplicate and the row is the comment's own turn. Reading `cancelled` or
      # `failed` there as "no longer coverage" would re-dispatch the duplicate
      # of a turn the user stopped, or that reassignment, agent teardown or a
      # workflow stop cancelled on purpose; restore! re-asks the comment's
      # eligibility but has no way to re-ask those decisions. A turn that failed
      # leaves a failed Task the product already shows and offers to retry,
      # which is the ordinary ending for every turn — not this restore's
      # subject, which is the dispatch that left nothing behind at all.
      # DeliveredHistoryDispatchTest reproduces that state and holds both.
      def self.claimed_comment_ids(task)
        Task.where(
          agent_id: task.agent_id, topic_id: task.topic_id,
          creative_id: task.creative_id, trigger_event_name: task.trigger_event_name
        ).where.not(id: task.id).select(:id, :trigger_event_payload).flat_map { |other|
          other_payload = other.trigger_event_payload
          next [] unless other_payload.is_a?(Hash)

          [ other_payload.dig("comment", "id") ] + Array(other_payload[TaskCoalescer::PAYLOAD_KEY])
        }.compact.map(&:to_i)
      end
      private_class_method :claimed_comment_ids

      # The comments the history window carried *whole*, read off the tag
      # MessageBuilder#append_chat_history writes. A window entry can render a
      # comment without delivering it — a blob or a linked creative's subtree
      # rides only on the trigger path — and those entries go untagged, so this
      # record never claims them. That judgement lives with the builder, which
      # is the only place that knows what it rendered; see
      # MessageBuilder#delivered_whole?.
      def self.history_comment_ids(resolved)
        messages = resolved.is_a?(Hash) ? Array(resolved[:messages] || resolved["messages"]) : Array(resolved)
        messages.filter_map do |message|
          next unless message.is_a?(Hash)
          next unless (message[:kind] || message["kind"]).to_s == "chat_history"

          id = message[:comment_id] || message["comment_id"]
          id&.to_i
        end.uniq
      end
      private_class_method :history_comment_ids
    end
  end
end
