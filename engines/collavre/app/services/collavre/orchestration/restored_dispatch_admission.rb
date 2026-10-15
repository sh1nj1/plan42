# frozen_string_literal: true

module Collavre
  module Orchestration
    # Restoration admission and keep ownership must agree when no job is created.
    module RestoredDispatchAdmission
      def reject_restore!(task, comment_id)
        creative = Creative.find_by(id: task.creative_id)
        recorded_keep = task.trigger_event_payload&.dig(KeepDispatchRestoration::KEY)&.key?(comment_id.to_s)
        return unless recorded_keep || (creative&.keep_loop? && creative.data.dig("trigger", "loop", "current_comment_id") == comment_id.to_i)

        Task.transaction do
          row = Task.lock.find_by(id: task.id)
          payload = row&.trigger_event_payload
          next unless payload.is_a?(Hash)
          next if restored_ids_in(payload).include?(comment_id.to_i)

          rejected = (rejected_restore_ids_in(payload) + [ comment_id.to_i ]).uniq.sort
          row.update!(trigger_event_payload: payload.merge(DeliveryRecord::RESTORE_REJECTED_KEY => rejected))
        end
      end

      private

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
      def enqueue_restored(task, agent, event_name, context)
        with_current_keep_restore(task, context) { enqueue_admitted_restore(task, agent, event_name, context) }
      end

      def enqueue_admitted_restore(task, agent, event_name, context)
        decision = admitted_restore_decision(agent, context)
        comment_id = context.dig("comment", "id")
        return reject_restore!(task, comment_id) unless decision

        if decision[:timing] == :delayed
          enqueue_claimed(task, comment_id) do
            AiAgentJob.set(wait: decision[:delay]).perform_later(agent.id, event_name, context)
          end
        else
          enqueue_claimed(task, comment_id) { AiAgentJob.perform_later(agent.id, event_name, context) }
        end
      end

      def admitted_restore_decision(agent, context)
        unless Matcher.permits_creative_access?(context, agent)
          Rails.logger.info("[DeliveryRecord] Not restoring comment #{context.dig("comment", "id")}: agent #{agent.id} lost creative access")
          return
        end

        decision = Scheduler.new(context).schedule([ agent ]).first
        if decision && decision[:timing] == :rejected
          Rails.logger.info("[DeliveryRecord] Not restoring comment #{context.dig("comment", "id")}: scheduler rejected agent #{agent.id} (#{decision[:reason]})")
          return
        end
        decision
      end
    end
  end
end
