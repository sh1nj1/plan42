# frozen_string_literal: true

module Collavre
  module Workflow
    class Receipt < ApplicationRecord
      self.table_name = "workflow_receipts"
      belongs_to :execution, class_name: "Collavre::Workflow::Execution"

      def self.identity(invocation, event_name, source)
        return unless invocation
        data = invocation.stringify_keys
        unless data["source"] == source && source == "drop_trigger" && data["job_id"].present?
          raise ArgumentError, "Invalid workflow producer invocation"
        end
        { source: source, event_name: event_name, job_id: data["job_id"] }
      end

      def self.recover(identity)
        receipt = find_by(identity) if identity
        return unless receipt
        ActiveRecord.after_all_transactions_commit { Recovery.execution(receipt.execution) }
        receipt.execution.reload.outcome
      end
    end
  end
end
