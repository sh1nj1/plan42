# frozen_string_literal: true

module Collavre
  module Workflow
    module FixedAnchor
      def self.reason(task)
        admission = DispatchIdentity.task_admission(task)
        return "scope_changed" unless admission
        safety = Safety.new(admission.execution)
        safety.reason || ("permission_revoked" unless safety.permitted?(task.agent))
      end

      def self.validate!(task)
        return true unless task.workflow?
        error = reason(task)
        return true unless error
        cancel!(task, error)
        false
      end

      def self.cancel!(task, reason)
        return unless Safety::STOP_REASONS.include?(reason) && DispatchIdentity.task_admission(task)
        task.cancel_if_active!(workflow_stop_reason: reason)
      end

      def self.withdraw!(task)
        error = reason(task)
        error ? cancel!(task, error) : task.cancel_if_active!
      end
    end
  end
end
