# frozen_string_literal: true

module Collavre
  class Task
    module AsyncApproval
      extend ActiveSupport::Concern

      included do
        after_update_commit :resume_async_approvals, if: -> { saved_change_to_status? && done? }
      end

      def async_approval_gates
        Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: agent_id)
               .where.not(action: nil).select do |comment|
          payload = comment.approval_gate_action
          payload && payload["mode"] == "async" && payload["task_id"] == id
        end
      end

      private

      def resume_async_approvals
        return unless agent.cli_proxy_agent?

        async_approval_gates.each { |comment| AsyncApprovalResumeJob.perform_later(comment.id) }
      end
    end
  end
end
