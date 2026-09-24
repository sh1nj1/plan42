# frozen_string_literal: true

module Collavre
  # The committed gate is the durable recovery record if either enqueue is lost.
  class AsyncApprovalSweepJob < ApplicationJob
    queue_as :default

    def perform
      Comment.where.not(action_executed_at: nil).where("action LIKE ?", "%approval_gate%").find_each do |comment|
        next unless comment.approval_gate_action&.dig("mode") == "async"

        AsyncApprovalResumeJob.perform_now(comment.id)
      rescue StandardError => e
        Rails.logger.error("[AsyncApprovalSweepJob] Failed comment #{comment.id}: #{e.class}: #{e.message}")
      end
    end
  end
end
