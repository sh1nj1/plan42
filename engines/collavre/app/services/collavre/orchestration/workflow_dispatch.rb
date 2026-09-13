# frozen_string_literal: true

module Collavre
  module Orchestration
    module WorkflowDispatch
      extend ActiveSupport::Concern

      included do
        singleton_class.prepend FixedWorkflowRefresh
      end

      module FixedWorkflowRefresh
        def refresh_deferred_context!(task, **options)
          return Workflow::FixedAnchor.validate!(task) if task.workflow?
          super
        end
      end

      def dispatch(**options)
        dispatch_with_outcome(**options).agents
      end

      def dispatch_with_outcome(selected_agents: nil, selection: nil, context_for: nil, scheduling_hooks: nil, invocation: nil)
        identity = Workflow::Receipt.identity(invocation, @event_name, @context.dig("event", "source"))
        recovered = Workflow::Receipt.recover(identity)
        return recovered if recovered
        selection ||= prepare_selection unless selected_agents
        if selection&.workflow_rule
          return Workflow::Admission.new(@context, selection, invocation: invocation,
            context_for: context_for, scheduling_hooks: scheduling_hooks).call
        end
        selected = selected_agents || selection.agents
        agents = ordinary_dispatch(selected, selection, context_for, scheduling_hooks)
        Workflow::DispatchOutcome.new(agents: agents, workflow_execution_id: nil, reason: nil)
      end

      def ordinary_dispatch(selected, selection, context_for, scheduling_hooks)
        return [] if selected.empty?
        selection&.commit!
        decisions = scheduler.schedule(selected, scheduling_hooks: scheduling_hooks)
        scheduling_hooks&.scheduled(decisions.filter_map { |decision| decision[:agent] unless decision[:timing] == :rejected })
        enqueue_jobs(decisions, context_for: context_for)
      end
    end
  end
end
