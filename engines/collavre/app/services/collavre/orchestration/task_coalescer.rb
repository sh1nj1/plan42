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

      # Set when a payload's anchor is moved onto a comment the task was not
      # created for. AgentOrchestrator.delivered_comment_ids has to tell that
      # apart from a task answering its own trigger, and the only evidence
      # otherwise was comment.created_at against task.created_at — two rows
      # stamped by whichever process wrote them, which is why nothing else in
      # this turn's machinery orders by time either. A tie or a skew reads an
      # acquired anchor as an original one and the comment is answered twice,
      # or an original one as acquired and a promoted waiter is left with no
      # candidate and cancelled.
      ACQUIRED_ANCHOR_KEY = "acquired_comment_id"

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

      # Point a payload at a new trigger comment, recording the move.
      #
      # Both doors that move an anchor go through this — the refresh carrying a
      # waiter forward, and the re-anchor rescuing a task whose anchor was
      # deleted. They differ only in how they rebuild the merged list, and
      # keeping the anchor write itself in one place is what makes "this turn
      # acquired that comment" a fact the payload carries rather than one a
      # later reader has to reconstruct.
      #
      # A refresh that lands back on the anchor it started from is a documented
      # no-op, so the mark is written only when the id actually changes, and
      # never cleared: an anchor moved twice is still not the turn's own.
      #
      # A payload with no anchor at all is left unmarked. There is no move to
      # record, and this whole record is read to decide whether a *waiter* may
      # keep its turn — so where the payload cannot say, the side that cannot
      # discard someone's work is the one to take.
      #
      # @return [Hash] the updated payload (not saved)
      def self.reanchor_payload(payload, comment)
        previous_id = payload.dig("comment", "id")
        # The anchor block is rebuilt from Comment#dispatch_payload rather than
        # enumerated here. That method is the declared single source of truth
        # for what a comment_created dispatch carries, and everything in it
        # describes the anchor: "from_ai" is what AiAgentJob#record_loop_breaker_
        # turn reads to decide whether a turn was agent-started, so a move that
        # drops it exempts agent-to-agent work from the creative-retry breaker,
        # and "quoted_comment_id" is what binds a review to the comment it
        # quotes. Enumerating the keys here means the list falls behind the
        # payload the ordinary door builds, silently, one key at a time.
        #
        # Rebuilt, never merged onto: a key absent for this comment must be
        # absent afterwards. Carrying the previous anchor's "from_ai" or its
        # quoted comment forward is the same defect pointing the other way.
        moved = payload.merge(
          comment.dispatch_payload.slice(:comment).deep_stringify_keys,
          "chat" => SystemEvents::ContextBuilder.reanchor_chat(comment.content)
        )
        if previous_id && previous_id.to_i != comment.id
          moved[ACQUIRED_ANCHOR_KEY] = comment.id

          # The per-user CLI Proxy workspace is part of the anchor's security
          # context. A waiter initially carried for one person can be promoted
          # onto a later comment from another, so retaining the old principal
          # would run the new prompt with the first person's callback token.
          # Human anchors identify their own principal. An AI/system anchor
          # cannot reconstruct its initiating person from the Comment row, so
          # retain an explicit nil sentinel. Downstream resolution distinguishes
          # this security decision from an ordinary payload that never carried a
          # principal and must not fall through to the agent creator.
          if comment.user && !comment.user.ai_user?
            if moved.key?("workspace_user_id")
              moved["workspace_user_id"] = comment.user_id
            end
          else
            moved["workspace_user_id"] = nil
          end
        end
        # Both keys ContextBuilder *derives* from the anchor are rebuilt here
        # too — dispatch_payload does not carry them, because ContextBuilder
        # fills each one in with `||=` and does not run again on either of
        # these paths. "chat"/"mentioned_user" moves with the anchor above
        # (ContextBuilder.reanchor_chat); "sender" below.
        #
        # The payload's "sender" labels the trigger and is what
        # ClaudeChannelAdapter sends as author_id/author_name, and
        # SystemEvents::ContextBuilder only ever fills it in with `||=` — it does
        # not run again on either of these paths. A burst spanning two people
        # would otherwise put the first speaker's name on the second's words.
        SystemEvents::ContextBuilder.reanchor_sender(moved, comment)
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

      # Restrict a re-anchor query to comments that keep the task on the same
      # potential workspace principal. The current anchor is always retained as
      # the no-op candidate: an A2A payload may carry a human principal even
      # though its anchor was authored by an agent, while moving onto another
      # agent comment would deliberately turn that principal into explicit nil.
      # A verified human boundary applies before a per-user gateway is selected
      # because configuration may change while the task is queued. A fallback
      # creator is not evidence of who initiated an ordinary turn, so it keeps
      # the legacy refresh behavior until a per-user gateway requires fail-closed
      # handling.
      def self.reanchor_scope_for_workspace_principal(scope, task)
        principal = workspace_principal_for(task)
        return scope if principal.first == :fallback && !workspace_principal_isolated?(task.agent)

        anchor_id = (task.trigger_event_payload || {}).dig("comment", "id")
        compatible =
          case principal.first
          when :human
            scope.where(user_id: principal.second)
          when :unprovable
            scope.where(user_id: nil).or(scope.where(user_id: User.ai_agents.select(:id)))
          else
            scope.none
          end

        anchor_id ? compatible.or(scope.where(id: anchor_id)) : compatible
      end

      def self.workspace_principal_for(task)
        workspace_principals_for([ task ]).fetch(task.id)
      end

      def self.workspace_principal_isolated?(agent)
        agent&.cli_proxy_agent? && agent.agent_gateway.per_user?
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
          siblings = reject_other_workspace_principals(keep, siblings)
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

          # A waiter absorbed here may have parked with a per-deferral notice of
          # its own — the policy only has to have been off when it deferred and
          # on by the time this fold runs. That notice speaks for this one
          # waiter, so with the waiter cancelled it is a stop button that
          # selects a task no longer in the queue and cancels nothing at all.
          #
          # Nothing else would collect it either: the cancelled task will never
          # be promoted through cleanup_waiter_notice!, and the drained sweep
          # needs the topic queue to empty — which the survivor of this very
          # fold prevents. Same transaction as the cancellation, so the two
          # cannot come apart.
          Comment.remove_waiter_notices!(
            creative_id: @keep.creative_id, topic_id: @keep.topic_id, task_ids: absorbed_ids
          )

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

      # Coalesced comments are rendered into one trigger and execute under the
      # survivor's single workspace principal. Folding across people would let
      # one person's prompt run with another person's provider login and
      # callback permissions, so only siblings whose effective principal is
      # identical may be absorbed.
      def reject_other_workspace_principals(keep, siblings)
        return siblings if siblings.empty?

        principals = self.class.send(:workspace_principals_for, [ keep ] + siblings)
        keep_principal = principals.fetch(keep.id)
        siblings.select { |task| principals.fetch(task.id) == keep_principal }
      end

      def self.workspace_principals_for(tasks)
        payloads = tasks.to_h { |task| [ task.id, task.trigger_event_payload || {} ] }
        explicit_ids = payloads.values.filter_map do |payload|
          payload["workspace_user_id"] if payload.key?("workspace_user_id")
        end
        anchor_ids = payloads.values.filter_map { |payload| payload.dig("comment", "id") }
        agent_creators = User.where(id: tasks.map(&:agent_id).compact.uniq).pluck(:id, :created_by_id).to_h
        creator_ids = agent_creators.values.compact
        users = User.where(id: explicit_ids + creator_ids).index_by(&:id)
        comments = Comment.where(id: anchor_ids).includes(:user).index_by(&:id)

        tasks.to_h do |task|
          payload = payloads.fetch(task.id)
          principal = effective_workspace_principal(task, payload, users, comments, agent_creators)
          [ task.id, principal ]
        end
      end
      private_class_method :workspace_principals_for

      def self.effective_workspace_principal(task, payload, users, comments, agent_creators)
        if payload.key?("workspace_user_id")
          carried = users[payload["workspace_user_id"].to_i]
          return carried && !carried.ai_user? ? [ :human, carried.id ] : [ :unprovable ]
        end

        comment = comments[payload.dig("comment", "id").to_i]
        return [ :human, comment.user_id ] if comment&.user && !comment.user.ai_user?

        creator = users[agent_creators[task.agent_id]]
        [ :fallback, creator&.id ]
      end
      private_class_method :effective_workspace_principal

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
