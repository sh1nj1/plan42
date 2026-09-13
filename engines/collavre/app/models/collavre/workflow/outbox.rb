# frozen_string_literal: true

module Collavre
  module Workflow
    class Outbox < ApplicationRecord
      self.table_name = "workflow_outboxes"
      belongs_to :execution, class_name: "Collavre::Workflow::Execution"
      LEASE = 5.minutes
      MAX_ATTEMPTS = 3
      scope :unfinished, -> { where(state: %w[pending enqueued delivering]) }
      scope :ready, -> { unfinished.where("due_at <= ? AND (claimed_at IS NULL OR claimed_at <= ?)", Time.current, LEASE.ago) }

      def task
        Task.find_by(workflow_execution_id: execution_id, agent_id: agent_id) if agent_id
      end

      def finish!(reason = nil)
        update!(state: reason ? "failed" : "completed", reason: reason, claim_token: nil, claimed_at: nil)
      end

      def claim!
        token = SecureRandom.uuid
        changed = self.class.ready.where(id: id, attempts: ...MAX_ATTEMPTS).update_all(
          [ "claim_token = ?, claimed_at = ?, state = ?, attempts = attempts + 1", token, Time.current, "enqueued" ])
        token if changed == 1
      end

      def owned(token)
        self.class.where(id: id, claim_token: token, state: %w[enqueued delivering]).where("claimed_at > ?", LEASE.ago)
      end

      def deliver!(token)
        return unless owned(token).where(state: "enqueued").update_all(state: "delivering") == 1
        reload
        agent_id ? Materialization.new(self, token: token).call : Publication.new(self, token: token).call
        owned(token).update_all(state: "completed", claim_token: nil, claimed_at: nil)
      rescue StandardError => error
        owned(token).update_all(state: "pending", claim_token: nil, claimed_at: nil)
        Rails.logger.warn("[Workflow] outbox_id=#{id} error_class=#{error.class.name}")
      end
    end
  end
end
