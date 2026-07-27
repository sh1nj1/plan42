# frozen_string_literal: true

module Collavre
  module Orchestration
    # Folds several un-started agent tasks for one conversation turn into one.
    #
    # A burst of external events (a PR comment sync, a webhook batch) creates
    # several comments in the same topic within milliseconds, and each one
    # dispatches its own task. With topic_max_concurrent_jobs = 1 the extras
    # pile up as `queued` waiters, and AgentOrchestrator.refresh_deferred_context!
    # points every one of them at the same latest comment — so the agent answers
    # the same message once per waiter.
    #
    # Cancelling the extras is not sufficient: session-backed agents receive
    # only the :trigger message (SessionContextResolver#incremental_payload
    # drops chat history), so the intermediate comments would be lost entirely.
    # Their ids are therefore merged into the survivor's payload under
    # "merged_comment_ids", and MessageBuilder folds them into the trigger.
    class TaskCoalescer
      PAYLOAD_KEY = "merged_comment_ids"

      # Cancel un-started siblings of `keep_task` and absorb their trigger
      # comments into it.
      #
      # @param keep_task [Collavre::Task] the survivor
      # @param scope [:older, :all] which queued siblings to supersede.
      #   :older (default) is for the enqueue path, where `keep_task` is itself
      #   a fresh `queued` row and two concurrent dispatches must not cancel
      #   each other. :all is for the promotion path, where `keep_task` has
      #   already left `queued` — nothing can cancel it, and the waiters left
      #   behind are *newer*, so the id guard would absorb nothing.
      # @return [Array<Integer>] ids of the tasks that were absorbed
      def self.coalesce!(keep_task, scope: :older)
        new(keep_task, scope: scope).coalesce!
      end

      # Merge extra comment ids into a task payload without touching siblings.
      # Used when a refresh moves the anchor to a newer comment: the previous
      # anchor still has to reach the agent.
      #
      # @return [Hash] the updated payload (not saved)
      def self.absorb_into_payload(payload, comment_ids)
        merged = Array(payload[PAYLOAD_KEY]) + Array(comment_ids)
        anchor_id = payload.dig("comment", "id")
        merged = merged.compact.map(&:to_i).uniq
        merged -= [ anchor_id.to_i ] if anchor_id
        payload.merge(PAYLOAD_KEY => merged.sort)
      end

      def initialize(keep_task, scope: :older)
        @keep = keep_task
        @scope = scope
      end

      def coalesce!
        absorbed_ids = []

        Task.transaction do
          siblings = superseded_scope.lock.to_a
          comment_ids = siblings.flat_map { |t| trigger_comment_ids(t) }

          siblings.each do |task|
            task.task_actions.create!(
              action_type: "superseded",
              status: "done",
              payload: { "superseded_by_task_id" => @keep.id }
            )
            task.update!(status: "cancelled")
            absorbed_ids << task.id
          end

          if siblings.any?
            payload = self.class.absorb_into_payload(@keep.trigger_event_payload || {}, comment_ids)
            @keep.update!(trigger_event_payload: payload)
          end
        end

        if absorbed_ids.any?
          Rails.logger.info(
            "[TaskCoalescer] Task #{@keep.id} absorbed #{absorbed_ids.size} queued sibling(s): " \
            "#{absorbed_ids.join(', ')}"
          )
        end
        absorbed_ids
      end

      private

      # Only `queued` tasks are safe to supersede. A `pending` task may already
      # be riding an enqueued AiAgentJob; cancelling it makes that job return
      # early *without* draining the topic queue, stalling the topic.
      #
      # `id < keep.id` rather than "every other sibling": two dispatches
      # coalescing concurrently would otherwise cancel each other and leave no
      # survivor. Each run only ever supersedes strictly older rows.
      def superseded_scope
        rel = Task.where(
          agent_id: @keep.agent_id,
          topic_id: @keep.topic_id,
          creative_id: @keep.creative_id,
          trigger_event_name: @keep.trigger_event_name,
          status: "queued"
        ).where.not(id: @keep.id)
        rel = rel.where("id < ?", @keep.id) if @scope == :older
        rel.order(:id)
      end

      # The comment a task was going to answer, plus anything it had already
      # absorbed itself — coalescing has to be transitive or a second round
      # drops the first round's merges.
      def trigger_comment_ids(task)
        payload = task.trigger_event_payload || {}
        ([ payload.dig("comment", "id") ] + Array(payload[PAYLOAD_KEY])).compact
      end
    end
  end
end
