# frozen_string_literal: true

module Collavre
  class Task
    module WorkflowCompletion
      extend ActiveSupport::Concern
      TERMINAL = %w[done failed cancelled escalated].freeze

      included do
        belongs_to :workflow_execution, class_name: "Collavre::Workflow::Execution", optional: true
        after_update_commit :settle_workflow, if: :saved_change_to_status?
      end

      def workflow? = workflow_execution_id.present?

      def settle_workflow
        return unless workflow?
        execution_id = workflow_execution_id
        ActiveRecord.after_all_transactions_commit do
          Workflow::Recovery.execution(Workflow::Execution.find(execution_id))
        end
      end

      def workflow_result(previous_reply_id: nil)
        return workflow_stop_reason if authoritative_workflow_stop?
        return "task_failed" if %w[failed cancelled escalated].include?(status)
        return nil unless done?
        return "login_required" if trigger_event_payload&.key?("engine_login")
        return "task_failed" if ended_undelivered?
        association(:reply_comment).reset
        return "empty_reply" if unsuccessful_loop_response?
        reply = reply_comment
        return "scope_changed" if !reply && (previous_reply_id || workflow_anchor_evidence?)
        return workflow_reply_result(reply) if reply
        return "completed_no_anchor" if task_actions.where(status: "done", action_type: "review_updated").exists?
        "empty_reply"
      end

      private

      def authoritative_workflow_stop?
        TERMINAL.include?(status) && Workflow::Safety::STOP_REASONS.include?(workflow_stop_reason)
      end

      def workflow_anchor_evidence?
        task_actions.where(status: "done", action_type: "reply_created").any? do |action|
          action.payload&.dig("comment_id").present? && action.payload&.dig("partial") != true
        end
      end

      def workflow_reply_result(reply)
        return "permission_revoked" if reply.private? || !Creatives::PermissionChecker.current_allowed?(reply.creative_id, agent, :read)
        return "scope_changed" unless reply.creative_id == creative_id && reply.topic_id == topic_id
        return "empty_reply" if reply.content.blank? || reply.content == Comment::STREAMING_PLACEHOLDER_CONTENT
        finalized_response? ? "completed" : "empty_reply"
      end
    end
  end
end
