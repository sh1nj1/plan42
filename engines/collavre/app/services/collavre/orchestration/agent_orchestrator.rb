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

        # Step 2: Select responders (Arbiter) - Phase 2
        # For now, all candidates respond
        selected = arbiter.select(candidates)
        return [] if selected.empty?

        # Step 3: Schedule execution (Scheduler) - Phase 3
        # For now, immediate execution
        decisions = scheduler.schedule(selected)

        # Step 4: Enqueue jobs
        enqueue_jobs(decisions)
      end

      private

      def matcher
        @matcher ||= Matcher.new(@context)
      end

      def arbiter
        @arbiter ||= Arbiter.new(@context)
      end

      def scheduler
        @scheduler ||= Scheduler.new(@context)
      end

      def enqueue_jobs(decisions)
        decisions.filter_map do |decision|
          case decision[:timing]
          when :immediate
            AiAgentJob.perform_later(decision[:agent].id, @event_name, @context)
            decision[:agent]
          when :delayed
            AiAgentJob.set(wait: decision[:delay]).perform_later(
              decision[:agent].id, @event_name, @context
            )
            decision[:agent]
          when :rejected
            Rails.logger.info(
              "[Orchestrator] Agent #{decision[:agent].id} rejected: #{decision[:reason]}"
            )
            nil
          end
        end
      end
    end
  end
end
