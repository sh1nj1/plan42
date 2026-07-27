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
          cleanup_waiting_notices!(task)
          refresh_deferred_context!(task)
          revalidate_assignment!(task) unless task.status == "cancelled"

          if task.status == "cancelled"
            # refresh_deferred_context! found no eligible comment, or
            # revalidate_assignment! found the topic now assigned to another
            # agent. Either way this waiter is dead — try the next queued task.
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
      # creative/topic? Shared with AiAgentJob's late slot check so both defer
      # paths post at most one notice per topic.
      def self.topic_concurrency_notice_exists?(creative_id, topic_id)
        Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: nil,
                      topic_concurrency_defer: true)
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
        Comment.transaction do
          TopicSlot.lock!(topic_id, creative_id)
          next nil unless Task.queued_for_topic(topic_id, creative_id).exists?
          next nil if topic_concurrency_notice_exists?(creative_id, topic_id)

          yield
        end
      end

      def self.coalesce_promoted!(task)
        return unless PolicyResolver.new(task.trigger_event_payload || {}).coalesce_pending_tasks?

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
        return unless PolicyResolver.new(context).coalesce_pending_tasks?

        absorbed = []
        Task.transaction do
          TopicSlot.lock!(task.topic_id, task.creative_id)
          absorbed = TaskCoalescer.coalesce!(task, scope: :all)
          refresh_deferred_context!(task) if absorbed.any?
        end
        return if absorbed.empty?

        # The folded waiters may have been everything the topic's "⏳" notice
        # described, and nothing else will take it down: removal happens when a
        # promotion drains a *queued* waiter, and this fold left none. Scope the
        # cleanup to "nobody is waiting any more" rather than "a fold happened"
        # — another agent's waiter is not this agent's sibling and its wait is
        # still real.
        return if Task.queued_for_topic(task.topic_id, task.creative_id).exists?

        cleanup_waiting_notices!(task)
      end

      # Post the "⏳ waiting on the topic slot" notice for a deferral raised
      # outside #enqueue_jobs — AiAgentJob's late slot check, which catches
      # dispatches that passed the Scheduler before any Task row existed.
      # No-op when a notice for this creative/topic is already up.
      def self.post_topic_concurrency_notice(creative_id, topic_id)
        return if creative_id.nil?

        creative = Creative.find_by(id: creative_id)
        return unless creative

        reason_text = waiting_reason_text(:topic_concurrency, topic_id, creative_id)

        with_deduped_topic_notice(creative_id, topic_id) do
          creative.comments.create!(
            content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
            topic_id: topic_id,
            private: false,
            skip_default_user: true,
            topic_concurrency_defer: true
          )
        end
      end

      # Remove waiting notice comments (system messages) for this task's creative/topic.
      def self.cleanup_waiting_notices!(task)
        context = task.trigger_event_payload
        creative_id = context&.dig("creative", "id")
        topic_id = context&.dig("topic", "id")
        return unless creative_id

        Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: nil)
               .where("content LIKE ?", "⏳%")
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
      def self.refresh_deferred_context!(task)
        context = task.trigger_event_payload
        creative_id = context&.dig("creative", "id")
        return unless creative_id && context&.key?("topic")

        # Keeping a review out of TaskCoalescer is only half the boundary: the
        # refresh is the other door onto the anchor, and moving it forward turns
        # the in-place revision into a plain reply just as surely. A review
        # answers the comment it quotes or nothing at all, so leave it alone.
        return if review_anchor?(context)

        topic_id = context.dig("topic", "id")
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
        latest_comment = scope.first

        unless latest_comment
          task.update!(status: "cancelled")
          return
        end

        # Moving the anchor forward must not drop what the task was originally
        # going to answer. A session-backed agent only receives the :trigger
        # message (SessionContextResolver#incremental_payload), so a silently
        # replaced anchor is a comment the agent never sees at all.
        previous_anchor_id = context.dig("comment", "id")
        context["comment"] = {
          "id" => latest_comment.id,
          "content" => latest_comment.content,
          "user_id" => latest_comment.user_id
        }
        context["chat"] = { "content" => latest_comment.content }
        # The payload's "sender" is what labels the trigger and what
        # ClaudeChannelAdapter sends as author_id/author_name, and
        # SystemEvents::ContextBuilder only ever fills it in with `||=` — it does
        # not run again here. A burst spanning two people would otherwise put the
        # first speaker's name on the second's words.
        context = SystemEvents::ContextBuilder.reanchor_sender(context, latest_comment)
        # absorb_into_payload also drops the new anchor from the merged list, so
        # a comment promoted from "merged" back to "trigger" is not sent twice.
        context = TaskCoalescer.absorb_into_payload(context, [ previous_anchor_id ].compact)
        task.update!(trigger_event_payload: context)
      end
      private_class_method :refresh_deferred_context!

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

          # Guard: skip if agent already has a running task for this comment
          comment_id = @context.dig("comment", "id")
          if comment_id && Task.duplicate_running_for_comment?(agent.id, comment_id)
            Rails.logger.warn(
              "[AgentOrchestrator] Skipping enqueue: agent #{agent.id} already has a running task " \
              "for comment #{comment_id}"
            )
            next
          end

          case decision[:timing]
          when :immediate
            AiAgentJob.perform_later(agent.id, @event_name, @context)
            agent
          when :deferred
            waiter = Task.create!(
              name: "Response to #{@event_name}",
              status: "queued",
              trigger_event_name: @event_name,
              trigger_event_payload: @context,
              agent: agent,
              topic_id: @context.dig("topic", "id"),
              creative_id: @context.dig("creative", "id")
            )
            # A burst of comments queues one waiter each, and every one of them
            # would answer the same latest comment on promotion. Fold the
            # earlier ones into this newest waiter — merged, not dropped, so a
            # session-backed agent still receives their content.
            TaskCoalescer.coalesce!(waiter) if policy_resolver.coalesce_pending_tasks?
            post_waiting_notice(agent, decision)
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

      def post_waiting_notice(agent, decision)
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
        if deferred && policy_resolver.coalesce_pending_tasks?
          self.class.with_deduped_topic_notice(creative_id, topic_id) do
            create_waiting_notice(creative, topic_id, reason_text, deferred: deferred)
          end
        else
          create_waiting_notice(creative, topic_id, reason_text, deferred: deferred)
        end
      end

      def create_waiting_notice(creative, topic_id, reason_text, deferred:)
        creative.comments.create!(
          content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
          topic_id: topic_id,
          private: false,
          skip_default_user: true,
          # Only :deferred queues a topic waiter; mark it so its stop button can
          # target the blocker. :delayed (busy / rate_limited) notices stay false.
          topic_concurrency_defer: deferred
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
