# frozen_string_literal: true

module Collavre
  module AiAgent
    # An explicit principal, including nil, takes precedence over the anchor author.
    class TaskWorkspaceUser
      def self.resolve(task)
        payload = task.trigger_event_payload || {}
        user =
          if payload.key?("workspace_user_id")
            User.find_by(id: payload["workspace_user_id"])
          else
            Comment.find_by(id: payload.dig("comment", "id"))&.user
          end

        user unless user&.ai_user?
      end
    end
  end
end
