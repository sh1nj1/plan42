# frozen_string_literal: true

module Collavre
  module Orchestration
    module JobEnqueue
      private

      def enqueue_jobs(decisions, context_for:, require_enqueue_ack: false, ordinary_delivery: nil)
        decisions.filter_map do |decision|
          agent = decision[:agent]
          next unless ordinary_delivery.nil? || ordinary_delivery.permitted?(agent)
          context = context_for_agent(agent, context_for)
          log_decision(decision)

          # A rejected decision is not a dispatch, so neither guard below
          # applies to it. Both ask "is this dispatch redundant?", which is only
          # a question about work that was going to run: the scheduler has
          # already refused this one, over an exhausted quota or a loop breaker
          # that fired. Recording a drop against it would make
          # DeliveryRecord.restore! owe a turn for work nothing scheduled, and
          # the restore enqueues AiAgentJob directly — past the very check that
          # did the refusing, so the quota is exceeded or the broken loop
          # restarted. Reporting the agent would be the same mistake in the
          # other direction: nothing is answering, and an empty result is how a
          # caller learns that.
          if decision[:timing] == :rejected
            ordinary_delivery&.record!(agent, "rejected")
            next
          end

          if already_handled?(agent, context)
            ordinary_delivery&.record!(agent, "handled")
            next agent
          end

          enqueue_scheduled(agent, context, decision, require_enqueue_ack, ordinary_delivery)
        end
      end

      def already_handled?(agent, context)
        # Guard: skip if agent already has a running task for this comment.
        # Handled, not unscheduled — see the drop guard below for why the two
        # are different answers and what reads them apart.
        comment_id = context.dig("comment", "id")
        if Workflow::TaskAdmission.duplicate_dispatch?(context, agent)
          Rails.logger.warn(
            "[AgentOrchestrator] Skipping enqueue: agent #{agent.id} already has a running task " \
            "for comment #{comment_id}"
          )
          return true
        end

        # Guard: an in-flight turn has already been given this comment. It
        # reached the agent inside that turn's chat history, so a turn of its
        # own would answer something the agent has read — and parking it as a
        # waiter costs a "⏳" notice and a promotion round-trip for a reply
        # nobody is waiting on. Drop it instead of queueing it.
        #
        # Nothing is recorded for a session-backed agent (it is sent only its
        # :trigger), so nothing is dropped for one either — those bursts still
        # go through TaskCoalescer, which merges rather than discards.
        #
        # Dropped only if the covering turn will take responsibility for it:
        # claim_drop! re-reads that turn's status under a lock and refuses if
        # it has already ended, because a turn that has ended has already run
        # its restore and would leave this comment with nobody to answer it.
        #
        # The agent is still returned. What this method reports is who will
        # answer, not how many turns it started — a :deferred decision
        # returns its agent although all it created was a queued row — and a
        # drop says this agent is answering that comment inside a turn
        # already running. Reporting nothing is how a caller learns *no agent
        # was scheduled*: DropTriggerJob#dispatch_trigger raises
        # DispatchFailedError on an empty result and retries a trigger that
        # was covered, three times, and calls the job failed at the end of it.
        covering = DeliveryRecord.covering_task(agent, comment_id, context, @event_name)
        if covering && DeliveryRecord.claim_drop!(covering, comment_id)
          Rails.logger.info(
            "[AgentOrchestrator] Dropping dispatch: comment #{comment_id} was already " \
            "delivered to agent #{agent.id} by in-flight task #{covering.id}"
          )
          return true
        end

        false
      end

      def enqueue_scheduled(agent, context, decision, require_enqueue_ack, ordinary_delivery)
        case decision[:timing]
        when :immediate, :delayed
          enqueue_agent_job(agent, context, decision, require_enqueue_ack: require_enqueue_ack)
          ordinary_delivery&.record!(agent, "handled")
          post_waiting_notice(agent, decision) if decision[:timing] == :delayed
          agent
        when :deferred
          waiter = park_waiter(agent, context)
          ordinary_delivery&.record!(agent, waiter ? "handled" : "rejected")
          return unless waiter

          post_waiting_notice(agent, decision, waiter: waiter)
          agent
        end
      end

      def enqueue_agent_job(agent, context, decision, require_enqueue_ack:)
        queue = decision[:timing] == :delayed ? AiAgentJob.set(wait: decision[:delay]) : AiAgentJob
        job = queue.perform_later(agent.id, @event_name, context)
        # Child publication must remain recoverable when an adapter rejects
        # enqueue without raising. Keep the legacy array API's default behavior.
        raise ActiveJob::EnqueueError if require_enqueue_ack && !(job && job.successfully_enqueued?)
      end
    end
  end
end
