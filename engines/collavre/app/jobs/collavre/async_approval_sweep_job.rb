# frozen_string_literal: true

module Collavre
  # The committed gate is the durable recovery record if either enqueue is lost.
  class AsyncApprovalSweepJob < ApplicationJob
    queue_as :default

    def perform
      Comment.where(async_approval_recovery_pending: true).find_each do |comment|
        next unless recovery_pending?(comment)

        AsyncApprovalResumeJob.perform_now(comment.id)
      rescue StandardError => e
        Rails.logger.error("[AsyncApprovalSweepJob] Failed comment #{comment.id}: #{e.class}: #{e.message}")
      end
    end

    private

    def recovery_pending?(comment)
      comment.with_lock do
        next false unless comment.async_approval_recovery_pending?
        next true if recoverable?(comment)

        comment.update!(async_approval_recovery_pending: false)
        false
      end
    end

    def recoverable?(comment)
      payload = comment.approval_gate_action
      return false unless payload&.dig("mode") == "async" && payload["decision"]
      return false if comment.private? || !comment.topic

      origin = Task.find_by(id: payload["task_id"], agent_id: comment.user_id,
                            topic_id: comment.topic_id, creative_id: comment.creative_id)
      return false unless origin && origin.status.in?(%w[running done])
      return false unless comment.user.cli_proxy_agent? && comment.creative.has_permission?(comment.user, :feedback)
      return true unless payload["resume_task_id"]

      Task.where(id: payload["resume_task_id"], status: %w[queued pending]).exists?
    end
  end
end
