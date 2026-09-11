# frozen_string_literal: true

module Collavre
  module Orchestration
    # Owns the "⏳ waiting on the topic slot" notices: the reason text a waiting
    # user reads, the locks that decide whether a notice is still warranted, the
    # single row each door is allowed to write, and the cleanup that takes it
    # down again.
    #
    # Two doors defer a dispatch — AgentOrchestrator#enqueue_jobs, and
    # AiAgentJob's late slot check for dispatches that passed the Scheduler
    # before any Task row existed — and they have to agree about when a burst
    # becomes one notice, which waiter a notice speaks for, and when it comes
    # back down. Both arrive here so that agreement is one implementation rather
    # than two that drift.
    class WaitingNoticeManager
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
      # Asked under the lock .post takes, so "nobody is queued" is
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
      # outside AgentOrchestrator#enqueue_jobs — AiAgentJob's late slot check,
      # which catches dispatches that passed the Scheduler before any Task row
      # existed.
      # No-op when a notice for this creative/topic is already up — unless
      # coalescing is off for this dispatch, in which case its waiter is nobody
      # else's to speak for and gets a notice of its own, exactly as the enqueue
      # door does. Leaving one door deduplicated and the other not is what breaks
      # the opt-out's 1:1.
      def self.post_topic_concurrency_notice(creative_id, topic_id, context = nil, agent: nil, waiter: nil)
        post(
          creative_id, topic_id, :topic_concurrency, deferred: true, waiter: waiter,
          # Falling back for a caller without a waiter: there is no row to ask.
          shared_without_waiter: -> { PolicyResolver.new(context || {}).coalesce_pending_tasks_for?(agent) }
        )
      end

      # Post the one "⏳" notice a deferred or delayed dispatch is entitled to,
      # under whichever guard its scope calls for.
      #
      # Coalescing collapses a burst of deferrals into one waiter, so a notice
      # per deferral would leave N-1 dead ends pointing at the same blocker.
      # Keep exactly one topic-concurrency notice per creative/topic — and take
      # the check and the insert under one lock, since a burst is precisely when
      # an unserialized check reads stale.
      #
      # The scope is taken from the waiter, which recorded it under the admission
      # lock when it was parked. One answer for the fold, the notice and the
      # shared notice's stop button, rather than the same question asked at three
      # moments a policy change can fall between. `shared_without_waiter` is the
      # fallback for a caller that has no waiter to ask — a :delayed dispatch
      # never parks one — and is called only then.
      def self.post(creative_id, topic_id, reason_key, deferred:, shared_without_waiter:, waiter: nil)
        return if creative_id.nil?

        creative = Creative.find_by(id: creative_id)
        return unless creative

        reason_text = waiting_reason_text(reason_key, topic_id, creative_id)
        shared = deferred && (waiter ? waiter.waiting_notice_scope == Comment::WAITING_NOTICE_TOPIC
                                     : shared_without_waiter.call)
        write = lambda do
          create_notice!(creative, topic_id, reason_text,
                         deferred: deferred, shared: shared, waiter: waiter)
        end

        if shared
          with_deduped_topic_notice(creative_id, topic_id, &write)
        elsif deferred
          # The waiter is committed and its notice posted afterwards, so the
          # window with_live_waiter closes is open on both doors — see that
          # method.
          with_live_waiter(waiter, creative_id, topic_id, &write)
        else
          # :delayed. The dispatch is still going to run, so there is no waiter
          # for this notice to speak for and nothing for the guard to ask about.
          write.call
        end
      end

      def self.create_notice!(creative, topic_id, reason_text, deferred:, shared:, waiter:)
        creative.comments.build(
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
        ).tap(&:save!)
      rescue ActiveRecord::RecordNotSaved => error
        # A delayed job is already queued when this notice is posted. Topic
        # relocation may invalidate only the stale notice in that gap.
        raise unless error.record.errors.include?(:topic)
      end
      private_class_method :create_notice!

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
    end
  end
end
