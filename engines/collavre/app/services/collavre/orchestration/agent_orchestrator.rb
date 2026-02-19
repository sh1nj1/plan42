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

      def self.dequeue_next_for_topic(topic_id)
        task = Task.queued_for_topic(topic_id).first
        return unless task

        updated = Task.where(id: task.id, status: "queued").update_all(status: "pending")
        if updated > 0
          task.reload
          refresh_deferred_context!(task)

          if task.status == "cancelled"
            # refresh_deferred_context! cancelled this task (no eligible comment),
            # try the next queued task for this topic.
            dequeue_next_for_topic(topic_id)
          else
            AiAgentJob.perform_later(task)
          end
        end
      end

      # Refresh trigger_event_payload so the deferred agent sees the latest
      # conversation state instead of the stale snapshot from enqueue time.
      # Skips AI agent's own comments to prevent self-response loops.
      # Cancels the task if no eligible comment remains.
      def self.refresh_deferred_context!(task)
        context = task.trigger_event_payload
        creative_id = context&.dig("creative", "id")
        return unless creative_id && context&.key?("topic")

        topic_id = context.dig("topic", "id")
        scope = Comment
          .where(creative_id: creative_id, topic_id: topic_id, private: false)
          .where.not(user_id: task.agent_id)
          .order(created_at: :desc)
        latest_comment = scope.first

        unless latest_comment
          task.update!(status: "cancelled")
          return
        end

        context["comment"] = {
          "id" => latest_comment.id,
          "content" => latest_comment.content,
          "user_id" => latest_comment.user_id
        }
        context["chat"] = { "content" => latest_comment.content }
        task.update!(trigger_event_payload: context)
      end
      private_class_method :refresh_deferred_context!

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

          case decision[:timing]
          when :immediate
            AiAgentJob.perform_later(agent.id, @event_name, @context)
            agent
          when :deferred
            Task.create!(
              name: "Response to #{@event_name}",
              status: "queued",
              trigger_event_name: @event_name,
              trigger_event_payload: @context,
              agent: agent,
              topic_id: @context.dig("topic", "id")
            )
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
        timing = decision[:timing]
        reason = decision[:reason]
        topic_id = @context.dig("topic", "id") || "main"

        case timing
        when :immediate
          Rails.logger.info(
            "[Orchestrator] Agent #{agent.id} (#{agent.name}) → immediate " \
            "(event=#{@event_name}, topic=#{topic_id})"
          )
        when :deferred
          Rails.logger.info(
            "[Orchestrator] Agent #{agent.id} (#{agent.name}) → deferred: #{reason} " \
            "(event=#{@event_name}, topic=#{topic_id})"
          )
        when :delayed
          Rails.logger.info(
            "[Orchestrator] Agent #{agent.id} (#{agent.name}) → delayed #{decision[:delay]}s: #{reason} " \
            "(event=#{@event_name}, topic=#{topic_id})"
          )
        when :rejected
          Rails.logger.info(
            "[Orchestrator] Agent #{agent.id} (#{agent.name}) → rejected: #{reason} " \
            "(event=#{@event_name}, topic=#{topic_id})"
          )
        end
      end

      def post_waiting_notice(agent, decision)
        creative_id = @context.dig("creative", "id")
        topic_id = @context.dig("topic", "id")
        return unless creative_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        reason_key = decision[:reason] || :unknown
        reason_text = I18n.t(
          "collavre.orchestration.waiting_reasons.#{reason_key}",
          default: reason_key.to_s.humanize
        )

        creative.comments.create!(
          content: I18n.t("collavre.orchestration.waiting_notice", reason: reason_text),
          user: agent,
          topic_id: topic_id,
          private: true
        )
      end
    end
  end
end
