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

      # The statuses a survivor may still be in when a fold runs: both enqueue
      # doors hand over a `queued` row and both start-of-turn doors a `pending`
      # one. Anything else means it lost its turn between the caller reading it
      # and this transaction.
      UNSTARTED_STATUSES = %w[queued pending].freeze

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
        return [] if review_trigger?(@keep)

        absorbed_ids = []

        Task.transaction do
          # Lock the survivor together with its siblings, and re-read its status
          # from the locked row. The survivor is the caller's snapshot: deleting
          # its anchor cancels it through Comment#cancel_pending_tasks, which
          # holds no lock this method waits on. Folding on a stale object would
          # cancel every still-valid sibling and merge the whole burst onto a
          # task AiAgentJob abandons on sight — and those siblings have no task
          # of their own left to answer them.
          #
          # One id-ordered statement rather than locking @keep first: in the
          # :older scope the survivor's id is above every sibling's, so taking it
          # first would descend where a concurrent fold ascends, which is the
          # shape a deadlock needs.
          locked = Task.where(id: superseded_scope.pluck(:id) + [ @keep.id ])
                       .order(:id).lock.index_by(&:id)
          keep = locked[@keep.id]
          next unless keep && UNSTARTED_STATUSES.include?(keep.status)

          # Status is re-checked against the locked rows too: a sibling promoted
          # or cancelled since the id read above is no longer ours to supersede.
          siblings = reject_review_triggers(
            locked.values.select { |t| t.id != keep.id && t.status == "queued" }
          )
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
            # Merge onto the locked row's payload, but write through the
            # caller's own object: dequeue_next_for_topic hands that same
            # instance to refresh_deferred_context! immediately after this, and
            # it has to see the ids merged here rather than its pre-fold copy.
            payload = self.class.absorb_into_payload(keep.trigger_event_payload || {}, comment_ids)
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

      # A Review request is an action bound to one comment, not one more message
      # in the burst. AiAgentService and ResponseFinalizer read review behaviour
      # off the surviving anchor alone (Comment#review_message? plus its
      # quoted_comment), so folding across that boundary breaks both ways: an
      # absorbed review silently degrades into a normal reply, and a surviving
      # review overwrites the quoted comment with text that also answers an
      # unrelated message. Reviews therefore neither absorb nor get absorbed —
      # they keep their own turn, which is the only shape ReviewHandler can run.
      def review_trigger?(task)
        anchor_id = (task.trigger_event_payload || {}).dig("comment", "id")
        anchor_id.present? && Comment.review_message_ids([ anchor_id ]).any?
      end

      # One query for the whole burst rather than review_trigger? per sibling.
      def reject_review_triggers(siblings)
        anchors = siblings.filter_map { |t| (t.trigger_event_payload || {}).dig("comment", "id") }
        review_ids = Comment.review_message_ids(anchors).to_set
        return siblings if review_ids.empty?

        siblings.reject do |task|
          review_ids.include?((task.trigger_event_payload || {}).dig("comment", "id").to_i)
        end
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
