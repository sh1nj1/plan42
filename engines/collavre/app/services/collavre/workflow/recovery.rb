# frozen_string_literal: true

module Collavre
  module Workflow
    module Recovery
      def self.execution(execution)
        Settlement.new(execution).call if execution.reload.open?
        execution.outboxes.unfinished.find_each { |row| outbox(row) }
        CommentNotificationDelivery.where(workflow_execution_id: execution.id).find_each(&:enqueue_push!)
      rescue StandardError => error
        Rails.logger.warn("[Workflow] execution_id=#{execution.id} recovery_error=#{error.class.name}")
      end

      def self.outbox(row)
        if row.agent_id && row.task
          row.finish!
          return
        end
        error = Safety.new(row.execution).reason
        error ||= "task_failed" if row.agent_id && !row.execution.open?
        if error
          row.finish!(error)
          Settlement.new(row.execution).stop!(error) if row.execution.open?
          return
        end
        return unless Outbox.ready.exists?(row.id)
        return exhaust(row) if row.attempts >= Outbox::MAX_ATTEMPTS
        token = row.claim!
        enqueue(row, token) if token
      end

      def self.enqueue(row, token)
        job = WorkflowOutboxJob.perform_later(row.id, token)
        raise ActiveJob::EnqueueError unless job && job.successfully_enqueued?
      rescue StandardError => error
        row.owned(token).where(state: "enqueued").update_all(state: "pending", claim_token: nil, claimed_at: nil)
        Rails.logger.warn("[Workflow] outbox_id=#{row.id} enqueue_error=#{error.class.name}")
      end

      def self.exhaust(row)
        changed = Outbox.ready.where(id: row.id, attempts: Outbox::MAX_ATTEMPTS..).update_all(state: "failed", reason: "delivery_failed", claim_token: nil, claimed_at: nil)
        Settlement.new(row.execution).stop!("delivery_failed") if changed == 1 && row.agent_id
      end
    end
  end
end
