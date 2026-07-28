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
      def self.record!(task, resolved)
        payload = task.trigger_event_payload
        return unless payload.is_a?(Hash)

        anchor_id = payload.dig("comment", "id").to_i
        return if anchor_id.zero?

        swallowed = history_comment_ids(resolved).select { |id| id > anchor_id }
        merged = (ids_in(payload) + swallowed).uniq.sort
        return if merged == ids_in(payload)

        task.update!(trigger_event_payload: payload.merge(KEY => merged))
      end

      def self.ids_in(payload)
        return [] unless payload.is_a?(Hash)

        Array(payload[KEY]).compact.map(&:to_i)
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
          ids_in(task.trigger_event_payload).include?(comment_id.to_i)
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
      # Restores only what nothing else is on the hook for. A comment swept into
      # this turn's history may still have a waiter of its own (parked before
      # the turn assembled, so never droppable), and promotion decides that
      # waiter's fate by re-reading this turn's status. Restoring it as well
      # would put two turns on one comment. "Has a row" is measured, not
      # inferred from what the drop believes it dropped.
      #
      # Each orphan is re-dispatched on its own, exactly as it would have been
      # had it never been dropped, and the ordinary admission path folds them
      # back together — rather than this method inventing a second merge rule
      # beside TaskCoalescer's.
      def self.restore!(task)
        payload = task.trigger_event_payload
        return unless payload.is_a?(Hash) && payload.key?("topic")

        orphaned = ids_in(payload) - claimed_comment_ids(task)
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
          AiAgentJob.perform_later(agent.id, task.trigger_event_name, restored_context(payload, comment))
        end
      end

      # The dispatch that was discarded — not a descendant of the turn that
      # discarded it. reanchor_payload is the single door for moving an anchor,
      # and the three bookkeeping keys are stripped after it because they
      # describe the dead turn: its own record would make a restored turn that
      # fails again restore the same comments a second time, its merged list
      # would re-send comments it was created for, and its acquired anchor would
      # label this turn's own trigger as borrowed.
      def self.restored_context(payload, comment)
        TaskCoalescer.reanchor_payload(payload, comment)
          .except(KEY, TaskCoalescer::PAYLOAD_KEY, TaskCoalescer::ACQUIRED_ANCHOR_KEY)
      end
      private_class_method :restored_context

      # Comment ids some other task in this turn's scope is already on the hook
      # for, as its trigger or as a merged block. Any status counts: what is
      # being asked is whether a dispatch exists at all, since the only thing
      # this restore undoes is a dispatch that was never allowed to become one.
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
