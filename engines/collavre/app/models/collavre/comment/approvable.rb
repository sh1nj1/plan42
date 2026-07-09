module Collavre
  class Comment < ApplicationRecord
    module Approvable
      extend ActiveSupport::Concern

      # A message that renders an approval button (pending) or an
      # approved/denied status label (decided) in the chat list — i.e. it
      # carries an `action` JSON payload. Both the `has_pending_action`
      # button (action.present? && action_executed_at.blank?) and the
      # ✅ 승인됨 / 🚫 거부됨 label (action_executed_at.present?, which implies
      # action.present?) roll up to this single condition.
      #
      # Such a message is a HUMAN decision surface and must never be dispatched
      # to an AI agent — regardless of who authored it or whether it has already
      # been decided. This is the single source of truth for that invariant,
      # enforced at every dispatch seam (Comment#dispatch_to_orchestration and
      # AiAgent::A2aDispatcher#dispatch).
      def approval_action?
        action.present?
      end

      def can_be_approved_by?(user)
        approval_status(user) == :ok
      end

      def approval_status(user)
        return :not_allowed unless user

        if action.blank?
          return :not_allowed unless approver_id == user&.id
          return :missing_action
        end

        begin
          payload = JSON.parse(action)
        rescue JSON::ParserError
          return :invalid_action_format
        end
        return :invalid_action_format unless payload.is_a?(Hash)

        actions = Array(payload["actions"])
        actions = [ payload ] if actions.empty?

        requires_admin = actions.any? do |item|
          next false unless item.is_a?(Hash)
          action_type = item["action"] || item["type"]
          action_type == "approve_tool"
        end

        if requires_admin && SystemSetting.mcp_tool_approval_required?
          return user.system_admin? ? :ok : :admin_required
        end

        return :missing_approver if approver_id.blank?
        return :not_allowed unless approver_id == user&.id

        :ok
      end

      def parsed_action_tool_name
        parsed = JSON.parse(action) rescue nil
        parsed&.dig("tool_name") || "unknown"
      end
    end
  end
end
