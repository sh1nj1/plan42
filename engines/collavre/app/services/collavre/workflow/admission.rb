# frozen_string_literal: true

module Collavre
  module Workflow
    # Selection is a preview. Only this boundary owns durable workflow effects.
    class Admission
      def initialize(context, selection, invocation: nil, context_for: nil, scheduling_hooks: nil)
        @context = context.except("workflow_execution_id")
        @selection = selection
        @rule = selection.workflow_rule
        @context_for, @scheduling_hooks = context_for, scheduling_hooks
        @identity = Receipt.identity(invocation, context["event_name"], context.dig("event", "source"))
      end

      def call
        existing = Receipt.recover(@identity)
        return existing if existing
        execution = Execution.transaction { persist }
        ActiveRecord.after_all_transactions_commit { after_ownership(execution) }
        execution.reload.outcome
      rescue ActiveRecord::RecordNotUnique
        Receipt.recover(@identity) || raise
      end

      private

      def persist
        chain = Chain.create_or_find_by!(correlation_id: @context.dig("event", "correlation_id"),
          creative_id: @context.dig("creative", "id"), topic_id: @context.dig("topic", "id").to_i) do |row|
          row.root_depth = @context.dig("event", "depth").is_a?(Integer) ? @context.dig("event", "depth") : 0
        end
        chain.with_lock do
          existing = chain.executions.find_by(input_event_id: @context.dig("event", "id"))
          next existing if existing
          execution = build_execution(chain)
          Receipt.create!(@identity.merge(execution: execution)) if @identity
          execution
        end
      end

      def build_execution(chain)
        row = new_execution(chain)
        error = EnvelopeValidation.reason(@context) || Safety.new(row).reason
        reserve_execution(row, error)
      end

      def new_execution(chain)
        chain.executions.build(input_event_id: @context.dig("event", "id"),
          rule_id: @rule.creative_id, context: @context,
          rule_snapshot: @selection.workflow_snapshot.deep_dup, selected_agent_ids: @selection.agents.map(&:id))
      end

      def reserve_execution(row, error)
        chain = row.chain
        decisions = error ? [] : Orchestration::Scheduler.new(@context).schedule(@selection.agents, scheduling_hooks: @scheduling_hooks)
        admitted = decisions.reject { |decision| decision[:timing] == :rejected }
        error ||= chain.reservation_reason(row.rule_id, @context.dig("event", "depth"), admitted.size)
        row.decisions = decisions.map { |d| d.except(:agent).merge(agent_id: d[:agent].id).deep_stringify_keys }
        row.save!
        return row.tap { row.seal!(error) } if error
        chain.update!(task_count: chain.task_count + admitted.size, step_count: chain.step_count + 1)
        row.update!(reserved: true)
        @new_reservation = true
        initialize_handler(row, admitted)
        row
      end

      def initialize_handler(row, admitted)
        case row.handler
        when "none" then row.seal!("ignored")
        when "human"
          row.update!(owner_id: Safety.new(row).owner&.id)
          HumanHandoff.new(row).persist!
        when "agent"
          return row.seal!(@selection.agents.empty? ? "no_eligible_agent" : "scheduler_rejected") if admitted.empty?
          admitted.each { |decision| create_obligation(row, decision) }
        end
      end

      def after_ownership(execution)
        if @new_reservation
          @selection.commit!
          @scheduling_hooks&.scheduled(User.where(id: execution.admissions.pluck(:agent_id)).to_a)
        end
      rescue StandardError => error
        Rails.logger.warn("[Workflow] callback execution_id=#{execution.id} error_class=#{error.class.name}")
      ensure
        Recovery.execution(execution)
      end

      def create_obligation(row, decision)
        override = @context_for&.call(decision[:agent]) || {}
        context = @context.deep_merge(override.deep_stringify_keys).merge("workflow_execution_id" => row.id)
        row.outboxes.create!(key: "agent:#{decision[:agent].id}", agent_id: decision[:agent].id,
          context: context, due_at: Time.current + (decision[:delay] || 0))
      end
    end
  end
end
