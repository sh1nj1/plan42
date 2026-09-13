# frozen_string_literal: true

module Collavre
  module Workflow
    class Execution < ApplicationRecord
      self.table_name = "workflow_executions"
      belongs_to :chain, class_name: "Collavre::Workflow::Chain"
      has_many :outboxes, class_name: "Collavre::Workflow::Outbox", dependent: :restrict_with_exception
      has_many :tasks, class_name: "Collavre::Task", foreign_key: :workflow_execution_id
      scope :unfinished, -> { where(sealed_at: nil) }

      def open? = sealed_at.nil?
      def emits = rule_snapshot["emits"].presence
      def handler = rule_snapshot.dig("handler", "type")
      def admissions = outboxes.where.not(agent_id: nil)

      def seal!(reason)
        update!(reason: reason, sealed_at: Time.current)
        Rails.logger.info("[Workflow] execution_id=#{id} rule_id=#{rule_id} event=#{context['event_name']} correlation_id=#{chain.correlation_id} depth=#{context.dig('event', 'depth')} relative_depth=#{context.dig('event', 'depth').to_i - chain.root_depth} reason=#{reason}")
      end

      def outcome
        DispatchOutcome.new(agents: User.where(id: admissions.pluck(:agent_id)).order(:id).to_a,
          workflow_execution_id: id, reason: reason)
      end
    end
  end
end
