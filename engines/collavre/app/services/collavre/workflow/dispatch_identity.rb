# frozen_string_literal: true

module Collavre
  module Workflow
    module DispatchIdentity
      def self.admission(context, agent_id)
        return unless context.is_a?(Hash) && context["workflow_execution_id"].present?
        row = Outbox.find_by(execution_id: context["workflow_execution_id"], key: "agent:#{agent_id}", agent_id: agent_id)
        return unless row
        expected = row.context
        keys = %w[event creative topic comment workflow_execution_id]
        return unless keys.all? { |key| context[key] == expected[key] }
        row if row.execution.context["event"] == context["event"]
      end

      def self.valid?(context, agent_id) = admission(context, agent_id).present?

      def self.task_admission(task)
        row = admission(task.trigger_event_payload, task.agent_id)
        row if row && row.execution_id == task.workflow_execution_id &&
          task.creative_id == row.execution.chain.creative_id && task.topic_id.to_i == row.execution.chain.topic_id
      end
    end
  end
end
