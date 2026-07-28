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
