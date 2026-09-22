# frozen_string_literal: true

module Collavre
  class Comment
    module ApprovalGate
      def approval_gate?
        approval_gate_action.present?
      end

      def approval_gate_denied?
        approval_gate_action&.dig("decision", "decision") == "denied"
      end

      def approval_gate_reason
        approval_gate_action&.dig("decision", "reason")
      end

      def approval_gate_action
        payload = JSON.parse(action.presence || "null")
        payload if payload.is_a?(Hash) && payload["action"] == "approval_gate"
      rescue JSON::ParserError
        nil
      end
    end
  end
end
