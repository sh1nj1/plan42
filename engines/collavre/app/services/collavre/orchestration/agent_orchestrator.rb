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
        task = Task.queued_for_topic(topic_id, creative_id).first
        return unless task

        updated = Task.where(id: task.id, status: "queued").update_all(status: "pending")
        if updated > 0
          task.reload
          # Fold the waiters left behind this one into it. dequeue promotes the
          # OLDEST queued task, so its same-agent siblings are all newer — they
          # would each be promoted in turn and, because
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

      def self.coalesce_promoted!(task)
        return unless PolicyResolver.new(task.trigger_event_payload || {}).coalesce_pending_tasks?

        TaskCoalescer.coalesce!(task, scope: :all)
      end
      private_class_method :coalesce_promoted!

      # Post the "⏳ waiting on the topic slot" notice for a deferral raised
      # outside #enqueue_jobs — AiAgentJob's late slot check, which catches
      # dispatches that passed the Scheduler before any Task row existed.
      # No-op when a notice for this creative/topic is already up.
      def self.post_topic_concurrency_notice(creative_id, topic_id)
        return if creative_id.nil?
        return if topic_concurrency_notice_exists?(creative_id, topic_id)

        creative = Creative.find_by(id: creative_id)
        return unless creative

        reason_text = waiting_reason_text(:topic_concurrency, topic_id, creative_id)

        creative.comments.create!(
          content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
          topic_id: topic_id,
          private: false,
          skip_default_user: true,
          topic_concurrency_defer: true
        )
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

        topic_id = context.dig("topic", "id")
        scope = Comment.public_only.without_approval_action
          .where(creative_id: creative_id, topic_id: topic_id)
          .where.not(user_id: [ task.agent_id, nil ])
          .order(created_at: :desc)
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
        # absorb_into_payload also drops the new anchor from the merged list, so
        # a comment promoted from "merged" back to "trigger" is not sent twice.
        context = TaskCoalescer.absorb_into_payload(context, [ previous_anchor_id ].compact)
        task.update!(trigger_event_payload: context)
      end
      private_class_method :refresh_deferred_context!

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
        return if Matcher.new(SystemEvents::ContextBuilder.new(context).build)
                         .assignment_permits?(agent)

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

        # Coalescing collapses a burst of deferrals into one waiter, so a notice
        # per deferral would leave N-1 dead ends pointing at the same blocker.
        # Keep exactly one topic-concurrency notice per creative/topic.
        return if decision[:timing] == :deferred &&
                  policy_resolver.coalesce_pending_tasks? &&
                  self.class.topic_concurrency_notice_exists?(creative_id, topic_id)

        reason_text = waiting_reason_text(decision[:reason] || :unknown, topic_id, creative_id)

        creative.comments.create!(
          content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
          topic_id: topic_id,
          private: false,
          skip_default_user: true,
          # Only :deferred queues a topic waiter; mark it so its stop button can
          # target the blocker. :delayed (busy / rate_limited) notices stay false.
          topic_concurrency_defer: decision[:timing] == :deferred
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
