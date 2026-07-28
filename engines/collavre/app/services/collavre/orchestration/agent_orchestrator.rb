# frozen_string_literal: true

module Collavre
  module Orchestration
    # AgentOrchestrator is the single entry point for AI agent routing and scheduling.
    # It coordinates the following components:
    # - Matcher: determines which agents are qualified to respond
    # - Arbiter: selects which agents will actually respond (floor control)
    # - Scheduler: decides when to execute (resource management)
    #
    # Usage:
    #   AgentOrchestrator.dispatch("comment_created", context)
    #
    class AgentOrchestrator
      def self.dispatch(event_name, context)
        new(event_name: event_name, context: context).dispatch
      end

      def self.dequeue_next_for_topic(topic_id, creative_id = nil)
        task = claim_next_waiter(topic_id, creative_id)
        if task
          # Fold the waiters left behind this one into it. dequeue promotes the
          # oldest *eligible* queued task, so its same-agent siblings are all
          # newer — they would each be promoted in turn and, because
          # refresh_deferred_context! points every one of them at the same
          # latest comment, replay the same answer. Absorb them here instead;
          # the refresh below then moves the anchor forward and keeps the
          # absorbed triggers in "merged_comment_ids".
          coalesce_promoted!(task)

          # `task` is the snapshot claim_next_waiter took, and the row can be
          # cancelled from outside between that claim and here: deleting the
          # comment it answers cancels a `pending` task through
          # Comment#cancel_pending_tasks, which holds no lock this path waits
          # on. TaskCoalescer re-reads the survivor under its own lock and
          # declines to fold onto a cancelled row — but declining leaves this
          # object still saying `pending`, and everything below reads it: the
          # refresh would write a payload onto a dead row and the check at the
          # bottom would enqueue it, where AiAgentJob reloads and returns
          # without draining. Re-read once, here, rather than at each of them.
          unless task.reload.status == "cancelled"
            cleanup_waiting_notices_if_drained!(task)
            refresh_deferred_context!(task)
            revalidate_assignment!(task) unless task.status == "cancelled"
          end

          if task.status == "cancelled"
            # The anchor was deleted under it, refresh_deferred_context! found
            # no eligible comment, or revalidate_assignment! found the topic now
            # assigned to another agent. Either way this waiter is dead — try
            # the next queued task.
            dequeue_next_for_topic(topic_id, creative_id)
          else
            AiAgentJob.perform_later(task)
          end
        end
      end

      # Promote the oldest waiter this topic can actually run, moving it
      # queued -> pending (a status that occupies the slot) so the claim is
      # visible to every other admission the moment it commits.
      #
      # Promotion is a slot hand-out just like AiAgentJob's admission, so it
      # takes the same lock and asks the same question. Without that, a caller
      # that merely observed *a* task finish would promote into a topic that is
      # still full (every terminal task in the topic calls here, including ones
      # that never held this slot), or hand a second concurrent turn to an agent
      # that is already running one — which TaskCoalescer, folding only `queued`
      # rows, could never merge after the fact.
      #
      # The oldest waiter is not always eligible: with topic_max > 1 the head of
      # the queue may belong to a busy agent while a later waiter can run now.
      # Stopping at the queue head would strand the whole queue behind it, so
      # scan in order for the first waiter that fits.
      def self.claim_next_waiter(topic_id, creative_id)
        claimed = nil

        Task.transaction do
          TopicSlot.lock!(topic_id, creative_id)

          candidate = Task.queued_for_topic(topic_id, creative_id).find do |waiter|
            TopicSlot.available_for?(
              waiter.agent_id, topic_id, creative_id, waiter.trigger_event_payload
            )
          end
          next if candidate.nil?

          updated = Task.where(id: candidate.id, status: "queued").update_all(status: "pending")
          claimed = candidate.reload if updated > 0
        end

        claimed
      end
      private_class_method :claim_next_waiter

      # Human-readable reason for the "⏳" waiting notice. For topic-concurrency
      # deferrals, name the agent(s) actually holding the topic's running slot so
      # a waiting user can see *who* is blocking them (and reach that task's stop
      # button) rather than an anonymous "another task is running" dead end.
      def self.waiting_reason_text(reason_key, topic_id, creative_id)
        if reason_key == :topic_concurrency && topic_id
          names = Task.running_for_topic(topic_id, creative_id)
                      .includes(:agent).filter_map { |t| t.agent&.name }.uniq
          if names.any?
            return I18n.t(
              "collavre.orchestration.waiting_reasons.topic_concurrency_with_agent",
              agent: names.join(", ")
            )
          end
        end

        I18n.t(
          "collavre.orchestration.waiting_reasons.#{reason_key}",
          default: reason_key.to_s.humanize
        )
      end

      # Is there already a "⏳" topic-concurrency waiting notice on this
      # creative/topic that stands for the topic as a whole? Shared with
      # AiAgentJob's late slot check so both defer paths post at most one shared
      # notice per topic.
      #
      # A per-deferral notice does not count. It speaks for one waiter, so
      # letting it suppress the shared one would leave a coalescing agent's
      # waiters with no notice at all whenever an opted-out agent happened to
      # defer into the topic first. Notices from before the mode was recorded do
      # count: they are the topic's only signal, and posting a second one beside
      # them is the duplication this guard exists to prevent.
      def self.topic_concurrency_notice_exists?(creative_id, topic_id)
        Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: nil,
                      topic_concurrency_defer: true)
               .where(waiting_notice_scope: [ nil, Comment::WAITING_NOTICE_TOPIC ])
               .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
               .exists?
      end

      # Check-then-insert the one waiting notice a topic is allowed, as a single
      # step. Both defer paths run for a *burst* — the case where every worker
      # reads "no notice yet" before any of them inserts — so an unserialized
      # check leaves N dead-end notices pointing at one blocker, and deleting one
      # of them cancels the waiters while the others linger.
      #
      # Serialize on the same row admission locks (TopicSlot.lock!): the workers
      # that compete for a notice are exactly the ones that competed for the
      # slot, so the loser reads the winner's committed notice.
      #
      # The same lock also decides whether a notice is still warranted at all.
      # The waiter commits before its notice goes up, so the blocker can finish
      # in between, promote it, and run cleanup_waiting_notices! before any
      # notice exists. A notice posted after that cleanup describes a wait that
      # is already over, and nothing will ever take it down: removal only
      # happens when a promotion drains a *queued* waiter, and there is none
      # left. Promotion takes this same row, so "still queued" read here is the
      # promotion's own before-or-after, not a guess.
      #
      # Yields only when a waiter is still queued and no notice exists yet;
      # returns nil otherwise.
      def self.with_deduped_topic_notice(creative_id, topic_id)
        with_live_topic_wait(creative_id, topic_id) do
          next nil if topic_concurrency_notice_exists?(creative_id, topic_id)

          yield
        end
      end

      # The "is anyone still waiting?" half on its own, without the "only one
      # notice per topic" half.
      #
      # With coalesce_pending_tasks off, each deferral keeps its own waiter, so
      # each one needs its own notice: a single notice standing for N
      # independent waiters turns its stop button into "cancel everyone's work"
      # (Comment#cancel_queued_tasks_for_waiting_notice reads "no sibling notice
      # left" as "this notice spoke for the topic"). The drain guard still
      # applies either way — a notice explaining a wait that is already over is
      # never removed by anything.
      def self.with_live_topic_wait(creative_id, topic_id)
        Comment.transaction do
          TopicSlot.lock!(topic_id, creative_id)
          next nil unless Task.queued_for_topic(topic_id, creative_id).exists?

          yield
        end
      end

      # The same guard for a notice that speaks for exactly one waiter.
      #
      # "Is anyone still waiting?" is the *shared* notice's question, and it
      # stays true for as long as any waiter is queued. A per-deferral notice
      # answers for one — and that one can be promoted between its row
      # committing and this lock, since the waiter is created and the notice
      # posted in two steps on both doors. With another deferral parked in the
      # same burst the topic-wide question then says yes while this waiter's
      # says no, and the notice goes up offering a stop button for a turn that
      # is already running.
      #
      # Nothing takes it back down. cleanup_waiter_notice! is the only path that
      # removes one, it runs during the promotion that just happened, and it
      # matched nothing because the notice did not exist yet; deleting it by
      # hand cancels nothing either, since a task-scoped notice selects its own
      # waiter and that waiter is no longer queued.
      #
      # Asked under the admission lock, so "still queued" is the promotion's own
      # before-or-after rather than a guess.
      def self.with_live_waiter(waiter, creative_id, topic_id, &block)
        # No waiter to speak for: the topic-wide question is all a caller
        # without one can be asked.
        return with_live_topic_wait(creative_id, topic_id, &block) if waiter.nil?

        Comment.transaction do
          TopicSlot.lock!(topic_id, creative_id)
          next nil unless Task.where(id: waiter.id, status: "queued").exists?

          yield
        end
      end

      def self.coalesce_promoted!(task)
        return unless PolicyResolver.new(task.trigger_event_payload || {})
                        .coalesce_pending_tasks_for?(task.agent)

        TaskCoalescer.coalesce!(task, scope: :all)
      end
      private_class_method :coalesce_promoted!

      # Fold one last time, at the moment execution actually begins.
      #
      # Promotion claims the slot (queued -> pending) and folds the waiters that
      # exist at that instant, but the task then sits `pending` until its
      # AiAgentJob runs. A comment arriving in that gap parks a waiter that
      # enqueue-time coalescing cannot reach: TaskCoalescer supersedes only
      # `queued` rows, and the claimed task has already left that status. Both
      # turns were still un-started — which is the invariant coalescing is
      # defined over, not "present when the slot was claimed" — so the last
      # un-started moment has to fold too.
      #
      # Serialized on the row admission locks. A concurrent dispatch either
      # commits its waiter before this reads the siblings, and is folded, or
      # after, and keeps its own turn against a task that is by then executing.
      # The re-anchor runs inside the same lock for the same reason: outside it,
      # the refresh could move the anchor onto a comment whose waiter is still
      # queued, and that comment would be answered twice.
      #
      # Only a `pending` task qualifies. That is the claimed-but-not-started
      # status; a resumed pending_approval task has already delivered its
      # trigger and run part of its turn, so folding new comments into it would
      # swallow them rather than answer them.
      def self.coalesce_at_start!(task)
        return unless task.status == "pending"

        context = task.trigger_event_payload || {}
        return unless context.key?("topic")
        return unless PolicyResolver.new(context).coalesce_pending_tasks_for?(task.agent)

        absorbed = []
        Task.transaction do
          TopicSlot.lock!(task.topic_id, task.creative_id)
          absorbed = TaskCoalescer.coalesce!(task, scope: :all)
          refresh_deferred_context!(task, absorbed_only: true) if absorbed.any?
        end
        return if absorbed.empty?

        # The folded waiters may have been everything the topic's "⏳" notice
        # described, and nothing else will take it down: removal happens when a
        # promotion drains a *queued* waiter, and this fold left none.
        cleanup_waiting_notices_if_drained!(task)
      end

      # Take the topic's "⏳" notice down, but only once nothing is waiting on
      # the slot any more.
      #
      # "A waiter left the queue" is not the same question. A topic gets exactly
      # one deduplicated notice, and with topic_max > 1 a promotion can leave
      # other agents queued — coalesce_promoted! absorbs same-agent siblings
      # only, and the queue head may be ineligible while a later waiter runs. So
      # an unconditional cleanup strips the wait/stop signal off a wait that is
      # still real, and nothing reposts it until the next deferral happens by.
      #
      # Asked under the lock post_waiting_notice takes, so "nobody is queued" is
      # that path's own before-or-after rather than a guess: a deferral either
      # commits its waiter before this reads, and keeps its notice, or after, and
      # posts its own.
      # …but that guard is about the *shared* notice, which is still describing a
      # real wait for as long as anyone is queued. A per-deferral notice speaks
      # for one waiter, so it comes down when that waiter leaves the queue and
      # not a moment later: with the opt-out and two waiters, promoting one
      # leaves the queue non-empty, and the notice for the task now running would
      # stay on screen with a stop button for a wait that is over.
      def self.cleanup_waiting_notices_if_drained!(task)
        Comment.transaction do
          TopicSlot.lock!(task.topic_id, task.creative_id)
          cleanup_waiter_notice!(task)

          # "Is anyone queued?" is the topic's question, not any one notice's.
          # A shared notice speaks for the queued waiters no per-deferral notice
          # claims, so a promotion that leaves only claimed waiters behind
          # leaves it representing nobody — a second "⏳" line whose stop button
          # selects nothing, kept up by the very waiter that is not its to
          # speak for. Ask each notice what it still stands for.
          Comment.remove_stranded_waiting_notices!(
            creative_id: task.creative_id, topic_id: task.topic_id
          )
          next if Task.queued_for_topic(task.topic_id, task.creative_id).exists?

          cleanup_waiting_notices!(task)
        end
      end
      private_class_method :cleanup_waiting_notices_if_drained!

      # Remove the per-deferral notice posted for this particular waiter, if it
      # had one. A shared notice is left alone — it is not this task's to take
      # down, and the drained check above is the question that governs it.
      def self.cleanup_waiter_notice!(task)
        Comment.remove_waiter_notices!(
          creative_id: task.creative_id, topic_id: task.topic_id, task_ids: task.id
        )
      end
      private_class_method :cleanup_waiter_notice!

      # Post the "⏳ waiting on the topic slot" notice for a deferral raised
      # outside #enqueue_jobs — AiAgentJob's late slot check, which catches
      # dispatches that passed the Scheduler before any Task row existed.
      # No-op when a notice for this creative/topic is already up — unless
      # coalescing is off for this dispatch, in which case its waiter is nobody
      # else's to speak for and gets a notice of its own, exactly as
      # #post_waiting_notice does on the enqueue door. Leaving one door
      # deduplicated and the other not is what breaks the opt-out's 1:1.
      def self.post_topic_concurrency_notice(creative_id, topic_id, context = nil, agent: nil, waiter: nil)
        return if creative_id.nil?

        creative = Creative.find_by(id: creative_id)
        return unless creative

        reason_text = waiting_reason_text(:topic_concurrency, topic_id, creative_id)
        shared = PolicyResolver.new(context || {}).coalesce_pending_tasks_for?(agent)
        post = lambda do
          creative.comments.create!(
            content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
            topic_id: topic_id,
            private: false,
            skip_default_user: true,
            topic_concurrency_defer: true,
            # What this notice speaks for, recorded rather than reconstructed
            # later from whichever siblings survive. See
            # Comment#cancel_queued_tasks_for_waiting_notice.
            waiting_notice_scope: shared ? Comment::WAITING_NOTICE_TOPIC : Comment::WAITING_NOTICE_TASK,
            waiting_notice_task_id: shared ? nil : waiter&.id
          )
        end

        if shared
          with_deduped_topic_notice(creative_id, topic_id, &post)
        else
          with_live_waiter(waiter, creative_id, topic_id, &post)
        end
      end

      # Remove waiting notice comments (system messages) for this task's creative/topic.
      def self.cleanup_waiting_notices!(task)
        context = task.trigger_event_payload
        creative_id = context&.dig("creative", "id")
        topic_id = context&.dig("topic", "id")
        return unless creative_id

        Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: nil)
               .where("content LIKE ?", "#{Comment::WAITING_NOTICE_PREFIX}%")
               .find_each do |notice|
          # System promotion, not user abandonment: do not let the destroy
          # callback cancel other still-queued waiters in this topic.
          notice.suppress_waiter_cancellation = true
          notice.destroy
        end
      end
      private_class_method :cleanup_waiting_notices!

      # Refresh trigger_event_payload so the deferred agent sees the latest
      # conversation state instead of the stale snapshot from enqueue time.
      # Skips AI agent's own comments to prevent self-response loops.
      # Cancels the task if no eligible comment remains.
      #
      # `absorbed_only` narrows the destination to the comments this turn is
      # actually answering — its anchor plus what coalescing folded into it.
      # A comment commits in its own transaction and its AiAgentJob creates the
      # queued task afterwards, so a comment can be visible here with no task
      # behind it yet: the topic lock orders task creation, not comment
      # visibility. Moving the anchor onto one of those has this turn answer a
      # comment it never absorbed, and when that job does run it parks a waiter
      # against the now-claimed task — the same comment answered twice.
      #
      # Only coalesce_at_start! passes it. Promotion's refresh has always taken
      # the newest comment in the topic ("the latest state, not the enqueue-time
      # snapshot" is the whole reason it exists) and that is a wider question
      # than this call site.
      def self.refresh_deferred_context!(task, absorbed_only: false)
        context = task.trigger_event_payload
        creative_id = context&.dig("creative", "id")
        return unless creative_id && context&.key?("topic")

        # Keeping a review out of TaskCoalescer is only half the boundary: the
        # refresh is the other door onto the anchor, and moving it forward turns
        # the in-place revision into a plain reply just as surely. A review
        # answers the comment it quotes or nothing at all, so leave it alone.
        #
        # "Not moved" is not "not checked", though. An ordinary anchor is
        # revalidated by having to be re-selected through the eligibility scope
        # below; a review that skips straight past it keeps whatever
        # trigger_event_payload cached, and the anchor is the one part of the
        # payload MessageBuilder renders without a filter. ReviewHandler#eligible?
        # only asks whether the *quoted* comment is private, so a review request
        # the user withdrew — or that was moved out of this turn's scope — while
        # it waited would still be delivered, and still drive an in-place
        # revision of the agent's comment.
        if review_anchor?(context)
          task.update!(status: "cancelled") unless anchor_still_in_turn?(context)
          return
        end

        topic_id = context.dig("topic", "id")
        previous_anchor_id = context.dig("comment", "id")
        delivered_ids = delivered_comment_ids(task, context)

        # ...and a review is no better as a *destination* than as an anchor. The
        # coalescer leaves a queued review alone, so an ordinary waiter promoted
        # first would re-anchor onto it and run ReviewHandler over a comment it
        # was never asked to revise — then the real review task repeats the
        # revision later. Skip reviews and take the newest ordinary comment,
        # which in the worst case is the waiter's own anchor (a no-op refresh)
        # rather than nothing, so this cannot strand a live waiter.
        scope = Comment.public_only.without_approval_action
          .where(creative_id: creative_id, topic_id: topic_id)
          .where.not(user_id: [ task.agent_id, nil ])
          .where.not(id: Comment.review_messages.where(creative_id: creative_id, topic_id: topic_id).select(:id))
          .order(id: :desc)

        # Narrowing the destination closes the door this call site opens, but the
        # promotion door still moves the anchor onto the newest comment in the
        # topic — deliberately, since that is the reason the refresh exists. So
        # ask the question from the delivery side as well: a comment already
        # handed to this agent is not handed to it again, whichever door moved
        # the anchor onto it. Asking here rather than at dispatch is what keeps
        # it loss-free — by promotion time the covering turn's status says
        # whether it actually delivered anything.
        scope = scope.where.not(id: delivered_ids) if delivered_ids.any?

        # When the filter above removed the waiter's *own* anchor, falling back
        # to an older comment is not a rescue.
        #
        # The refresh's worst case used to be a no-op: the waiter's own anchor
        # was always among the candidates, so "the newest eligible comment" was
        # never older than the comment the waiter was dispatched for. Delivery
        # filtering can now take that anchor away, and what is next is older —
        # a comment this waiter was not dispatched for, that predates the one it
        # was, and that the covering turn had in view when it answered the
        # anchor. Answering it is a second reply to settled conversation.
        #
        # Scoped to exactly that cause rather than a blanket "never move
        # backwards": an anchor that has left the turn for some other reason
        # (moved to another creative, made private) is a different question with
        # its own answer, and widening the floor to cover it would change what
        # promotion does to waiters this feature never touched.
        #
        # With nothing at or above the anchor left, `latest_comment` is nil and
        # the branch below cancels the waiter — which is the right outcome:
        # everything it could have said has been said.
        if previous_anchor_id && delivered_ids.include?(previous_anchor_id.to_i)
          scope = scope.where("id >= ?", previous_anchor_id)
        end

        if absorbed_only
          candidate_ids = (Array(context[TaskCoalescer::PAYLOAD_KEY]) + [ previous_anchor_id ])
            .compact.map(&:to_i).uniq
          return if candidate_ids.empty?

          scope = scope.where(id: candidate_ids)
        end

        latest_comment = scope.first

        unless latest_comment
          task.update!(status: "cancelled")
          return
        end

        # Moving the anchor forward must not drop what the task was originally
        # going to answer. A session-backed agent only receives the :trigger
        # message (SessionContextResolver#incremental_payload), so a silently
        # replaced anchor is a comment the agent never sees at all.
        #
        # reanchor_payload also records the move when it is one, which is what
        # delivered_comment_ids reads below: a comment this turn was handed
        # without having been created for it.
        context = TaskCoalescer.reanchor_payload(context, latest_comment)
        # absorb_into_payload also drops the new anchor from the merged list, so
        # a comment promoted from "merged" back to "trigger" is not sent twice.
        context = TaskCoalescer.absorb_into_payload(context, [ previous_anchor_id ].compact)
        # The merged list is rendered into the trigger exactly like the anchor, so
        # keeping the anchor off a delivered comment is only half of it: the
        # comment the refresh just displaced can itself be one an earlier turn
        # already answered.
        if delivered_ids.any?
          context[TaskCoalescer::PAYLOAD_KEY] = Array(context[TaskCoalescer::PAYLOAD_KEY]) - delivered_ids
        end
        task.update!(trigger_event_payload: context)
      end
      private_class_method :refresh_deferred_context!

      # Statuses that mean this agent was actually handed the task's trigger.
      #
      # `queued` and `pending` are excluded because nothing has been delivered
      # yet — those are the un-started rows TaskCoalescer folds, and treating a
      # merely claimed task as an answer is what would make this lossy.
      # `failed`, `cancelled` and `escalated` are excluded deliberately: a turn
      # that died may never have delivered anything, so the comments it held
      # stay answerable. That direction trades a possible duplicate after a
      # failure for never silencing a comment no task is left to answer.
      DELIVERED_STATUSES = %w[running delegated pending_approval done].freeze

      # Comment ids this agent has already been given in this topic by a turn that
      # was not created to answer them. MessageBuilder renders merged blocks into
      # the trigger exactly like the anchor, so both count as delivery.
      #
      # The distinction matters more than the delivery: the ordinary history of a
      # topic is one comment answered by its own turn, and *that* must silence
      # nothing, or every waiter standing behind an answered comment would be
      # cancelled. Two shapes say "this turn was not created for that comment",
      # and neither needs anything new recorded:
      #
      # - it sits in the turn's merged list — coalescing put it there, and the
      #   task it belonged to was superseded, so this turn is its only delivery;
      # - it is the anchor, and the payload records that the anchor was moved
      #   onto it — the refresh acquired it, which is the window this closes.
      #
      # An anchor a task was created for is that task's original trigger and is
      # deliberately not counted. Which of the two it is comes from the payload
      # (TaskCoalescer::ACQUIRED_ANCHOR_KEY, written by whichever door moved it)
      # rather than from comparing the comment's clock with the task's.
      #
      # Scoped by topic and creative, which also keeps workflow subtasks out:
      # Comments::WorkflowExecutor mints its own trigger comment in the child
      # creative with topic_id nil, so it can never be mistaken for a delivery of
      # a comment in this topic. Same trigger_event_name for the same reason
      # TaskCoalescer folds only within one — a different event over the same
      # comment is a different question.
      def self.delivered_comment_ids(task, context)
        others = Task.where(
          agent_id: task.agent_id,
          topic_id: context.dig("topic", "id"),
          creative_id: context.dig("creative", "id"),
          trigger_event_name: task.trigger_event_name,
          status: DELIVERED_STATUSES
        ).where.not(id: task.id).select(:id, :trigger_event_payload).reject { |other|
          # `done` is in DELIVERED_STATUSES because a finished turn delivered
          # what it read — except when the request never reached the provider,
          # which AiClient#chat swallows and AiAgentJob still finishes as
          # `done`. Such a turn silences nothing, for the same reason `failed`
          # is left out of the list; it just cannot be recognised by status.
          DeliveryRecord.handoff_failed?(other.trigger_event_payload)
        }

        acquired_anchors = others.filter_map { |other| acquired_anchor_id_in(other) }
        merged = others.flat_map { |other|
          Array(other.trigger_event_payload&.dig(TaskCoalescer::PAYLOAD_KEY)).compact.map(&:to_i)
        }
        # The third shape, and the one the dispatch doors cannot catch: a
        # non-session turn re-reads the topic when it assembles its payload, so
        # a comment that landed after that turn was dispatched can be swept into
        # its history window without ever being merged or re-anchored. A waiter
        # parked before the covering turn assembled is only discoverable here.
        swallowed = others.flat_map { |other| DeliveryRecord.ids_in(other.trigger_event_payload) }

        (acquired_anchors + merged + swallowed).uniq
      end
      private_class_method :delivered_comment_ids

      # The anchor of `other`, but only when `other` acquired it rather than
      # being created for it. The recorded id is compared against the anchor as
      # it stands now: a payload moved on again since carries the older id in
      # its merged list, which is counted separately.
      def self.acquired_anchor_id_in(other)
        payload = other.trigger_event_payload
        acquired = payload&.dig(TaskCoalescer::ACQUIRED_ANCHOR_KEY)
        anchor = payload&.dig("comment", "id")
        return nil if acquired.nil? || anchor.nil?

        anchor.to_i if acquired.to_i == anchor.to_i
      end
      private_class_method :acquired_anchor_id_in

      # May this turn still deliver the comment it is anchored on?
      #
      # Asked through MergedTriggerComments.in_turn — the same predicate the
      # renderer uses for the merged list and Matcher.permits_assignment? for the
      # mention — so an anchor cannot be delivered under rules the rest of the
      # payload is filtered by: public_only, no approval surface, and still in
      # this turn's creative/topic.
      def self.anchor_still_in_turn?(context)
        anchor_id = context.dig("comment", "id")
        return false if anchor_id.blank?

        AiAgent::MergedTriggerComments.in_turn([ anchor_id ], context).exists?
      end
      private_class_method :anchor_still_in_turn?

      def self.review_anchor?(context)
        anchor_id = context.dig("comment", "id")
        anchor_id.present? && Comment.review_message_ids([ anchor_id ]).any?
      end
      private_class_method :review_anchor?

      # Cancel a promoted waiter whose agent the topic's primary-agent assignment
      # now excludes. A queued task keeps the agent chosen when it was dispatched,
      # so a pin created or moved while it waited would otherwise be bypassed by
      # the very work it is supposed to silence.
      #
      # Runs AFTER refresh_deferred_context! so the check judges what the agent is
      # about to answer, not the stale snapshot: if the latest comment @mentions
      # this agent, the mention outranks the assignment and the task survives.
      # That refresh replaces the whole "chat" hash, dropping the resolved
      # mentioned_user, so rebuild the context to recompute it from the content.
      def self.revalidate_assignment!(task)
        context = task.trigger_event_payload
        return unless context&.key?("topic")

        agent = task.agent
        return unless agent
        return if Matcher.permits_assignment?(context, agent)

        Rails.logger.info(
          "[AgentOrchestrator] Cancelling queued task #{task.id}: topic #{task.topic_id} " \
          "is now assigned to another agent (agent=#{agent.id})"
        )
        task.update!(status: "cancelled")
      end
      private_class_method :revalidate_assignment!

      def initialize(event_name:, context:)
        @event_name = event_name
        # Build context ONCE here - no more duplicate builds
        @context = SystemEvents::ContextBuilder.new(context).build
        @context["event_name"] = event_name
      end

      def dispatch
        # Step 1: Find qualified agents (Matcher)
        candidates = matcher.match
        return [] if candidates.empty?

        # Step 2: Select responders (Arbiter) - with policy-based floor control
        selected = arbiter.select(candidates)
        return [] if selected.empty?

        # Step 3: Schedule execution (Scheduler) - Phase 3
        # For now, immediate execution
        decisions = scheduler.schedule(selected)

        # Step 4: Enqueue jobs
        enqueue_jobs(decisions)
      end

      private

      def policy_resolver
        @policy_resolver ||= PolicyResolver.new(@context)
      end

      def matcher
        @matcher ||= Matcher.new(@context)
      end

      def arbiter
        @arbiter ||= Arbiter.new(@context, policy_resolver: policy_resolver)
      end

      def scheduler
        @scheduler ||= Scheduler.new(@context, policy_resolver: policy_resolver)
      end

      def enqueue_jobs(decisions)
        decisions.filter_map do |decision|
          agent = decision[:agent]
          log_decision(decision)

          # Guard: skip if agent already has a running task for this comment.
          # Handled, not unscheduled — see the drop guard below for why the two
          # are different answers and what reads them apart.
          comment_id = @context.dig("comment", "id")
          if comment_id && Task.duplicate_running_for_comment?(agent.id, comment_id)
            Rails.logger.warn(
              "[AgentOrchestrator] Skipping enqueue: agent #{agent.id} already has a running task " \
              "for comment #{comment_id}"
            )
            next agent
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
          covering = DeliveryRecord.covering_task(agent, comment_id, @context, @event_name)
          if covering && DeliveryRecord.claim_drop!(covering, comment_id)
            Rails.logger.info(
              "[AgentOrchestrator] Dropping dispatch: comment #{comment_id} was already " \
              "delivered to agent #{agent.id} by in-flight task #{covering.id}"
            )
            next agent
          end

          case decision[:timing]
          when :immediate
            AiAgentJob.perform_later(agent.id, @event_name, @context)
            agent
          when :deferred
            waiter = park_waiter(agent)
            post_waiting_notice(agent, decision, waiter: waiter)
            agent
          when :delayed
            AiAgentJob.set(wait: decision[:delay]).perform_later(
              agent.id, @event_name, @context
            )
            post_waiting_notice(agent, decision)
            agent
          when :rejected
            nil
          end
        end
      end

      # Park this dispatch as a queued waiter and fold the earlier ones into it.
      #
      # A burst of comments queues one waiter each, and every one of them would
      # answer the same latest comment on promotion. Fold them — merged, not
      # dropped, so a session-backed agent still receives their content.
      #
      # Creating the row and folding its predecessors is ONE step, under the
      # lock AiAgentJob#admit_or_defer! already takes for the other enqueue
      # door. TaskCoalescer supersedes by `id < keep.id`, which reads as
      # "everything already parked" only while id order and commit order agree.
      # An unserialized insert lets them diverge: the higher-id waiter can
      # commit and fold first, seeing nothing, and the lower-id one then folds
      # nothing either because the survivor is newer than its guard allows.
      # Both are still folded at promotion (scope: :all) and again at execution
      # (coalesce_at_start!), so this is not a duplicate turn — but two doors
      # onto one queue should not disagree about when a burst becomes one
      # waiter, and only the serialized one holds without those later passes.
      def park_waiter(agent)
        topic_id = @context.dig("topic", "id")
        creative_id = @context.dig("creative", "id")
        waiter = nil

        Task.transaction do
          TopicSlot.lock!(topic_id, creative_id)
          waiter = Task.create!(
            name: "Response to #{@event_name}",
            status: "queued",
            trigger_event_name: @event_name,
            trigger_event_payload: @context,
            agent: agent,
            topic_id: topic_id,
            creative_id: creative_id
          )
          TaskCoalescer.coalesce!(waiter) if policy_resolver.coalesce_pending_tasks_for?(agent)
        end

        waiter
      end

      def log_decision(decision)
        agent = decision[:agent]
        topic_id = @context.dig("topic", "id") || "main"
        detail = [ decision[:timing], decision[:reason] ].compact.join(": ")
        detail += " #{decision[:delay]}s" if decision[:delay]
        Rails.logger.info(
          "[Orchestrator] Agent #{agent.id} (#{agent.name}) → #{detail} " \
          "(event=#{@event_name}, topic=#{topic_id})"
        )
      end

      def post_waiting_notice(agent, decision, waiter: nil)
        creative_id = @context.dig("creative", "id")
        topic_id = @context.dig("topic", "id")
        return unless creative_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        reason_text = waiting_reason_text(decision[:reason] || :unknown, topic_id, creative_id)
        deferred = decision[:timing] == :deferred

        # Coalescing collapses a burst of deferrals into one waiter, so a notice
        # per deferral would leave N-1 dead ends pointing at the same blocker.
        # Keep exactly one topic-concurrency notice per creative/topic — and take
        # the check and the insert under one lock, since a burst is precisely
        # when an unserialized check reads stale.
        shared = deferred && policy_resolver.coalesce_pending_tasks_for?(agent)
        if shared
          self.class.with_deduped_topic_notice(creative_id, topic_id) do
            create_waiting_notice(creative, topic_id, reason_text, deferred: deferred,
                                  shared: true, waiter: waiter)
          end
        elsif deferred
          # park_waiter commits the row and this posts its notice afterwards, so
          # the same window with_live_waiter closes on the late-admission door is
          # open here too — see that method.
          self.class.with_live_waiter(waiter, creative_id, topic_id) do
            create_waiting_notice(creative, topic_id, reason_text, deferred: deferred,
                                  shared: false, waiter: waiter)
          end
        else
          # :delayed. The dispatch is still going to run, so there is no waiter
          # for this notice to speak for and nothing for the guard to ask about.
          create_waiting_notice(creative, topic_id, reason_text, deferred: deferred,
                                shared: false, waiter: waiter)
        end
      end

      def create_waiting_notice(creative, topic_id, reason_text, deferred:, shared:, waiter:)
        creative.comments.create!(
          content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
          topic_id: topic_id,
          private: false,
          skip_default_user: true,
          # Only :deferred queues a topic waiter; mark it so its stop button can
          # target the blocker. :delayed (busy / rate_limited) notices stay false.
          topic_concurrency_defer: deferred,
          # …and only a :deferred notice speaks for a waiter at all, so only that
          # one records which. A :delayed notice never reaches
          # Comment#cancel_queued_tasks_for_waiting_notice.
          waiting_notice_scope: deferred ? (shared ? Comment::WAITING_NOTICE_TOPIC : Comment::WAITING_NOTICE_TASK) : nil,
          waiting_notice_task_id: (waiter&.id unless shared)
        )
      end

      # Human-readable reason for the "⏳" waiting notice. For topic-concurrency
      # deferrals, name the agent(s) actually holding the topic's running slot so
      # a waiting user can see *who* is blocking them (and reach that task's stop
      # button) rather than an anonymous "another task is running" dead end.
      def waiting_reason_text(reason_key, topic_id, creative_id)
        self.class.waiting_reason_text(reason_key, topic_id, creative_id)
      end
    end
  end
end
