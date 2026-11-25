# frozen_string_literal: true

module Collavre
  # Persists ownership of unread approval results before a reply commits.
  # The task identity is server-recorded at /notify; request IDs alone never
  # authorize handing off another task's or another agent's approvals.
  class ClaudeApprovalHandoff
    def self.finish!(task, request_ids)
      ids = Array(request_ids).map(&:to_s).uniq
      return [] if ids.empty?

      accepted = []
      Comment.where(user_id: task.agent_id, topic_id: task.topic_id, creative_id: task.creative_id)
             .where.not(action: nil).find_each do |comment|
        comment.with_lock do
          next unless comment.claude_channel_approval_request?
          payload = JSON.parse(comment.action)
          next unless ids.include?(payload["request_id"])
          next unless payload["origin_task_id"].to_s == task.id.to_s

          comment.update!(action: JSON.generate(payload.merge("turn_finished" => true)))
          accepted << payload["request_id"]
        end
      end
      accepted
    end
  end
end
