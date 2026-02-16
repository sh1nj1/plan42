module Collavre
  class Comment < ApplicationRecord
    module Approvable
      extend ActiveSupport::Concern

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
