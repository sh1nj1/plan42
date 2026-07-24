# frozen_string_literal: true

module Collavre
  module TriggerLoopHelpers
    extend ActiveSupport::Concern

    private

    # Find the last comment by the task's agent in the trigger topic,
    # scoped to comments created after the task was dispatched.
    def find_last_agent_comment(creative, topic, task)
      creative.comments
              .where(topic_id: topic.id, user_id: task.agent_id)
              .where("comments.created_at >= ?", task.created_at)
              .order(created_at: :desc)
              .first
    end

    # Single method to update loop state — avoids multiple DB writes per Job execution.
    # Only the keys passed in `changes` are updated; others are preserved.
    def update_loop_data(child_creative, **changes)
      data = child_creative.data || {}
      trigger = data["trigger"] || {}
      loop_data = trigger["loop"] || {}
      changes.each { |key, value| loop_data[key.to_s] = value }
      trigger["loop"] = loop_data
      data["trigger"] = trigger
      child_creative.update!(data: data)
    end

    # Post a system notice (no specific user author) in the trigger topic.
    def post_system_notice(creative, topic, content)
      creative.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        skip_default_user: true
      )
    end
  end
end
