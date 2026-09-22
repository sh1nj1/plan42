# frozen_string_literal: true

module Collavre
  class Task
    module ApprovalGateCleanup
      extend ActiveSupport::Concern

      included do
        before_update :clear_terminal_approval_gate
      end

      private

      def clear_terminal_approval_gate
        return unless status.in?(%w[done failed cancelled escalated])
        return unless pending_tool_call&.dig("kind") == "approval_gate"

        # Keep recovery data until the terminal state is committed atomically.
        self.pending_tool_call = nil
      end
    end
  end
end
