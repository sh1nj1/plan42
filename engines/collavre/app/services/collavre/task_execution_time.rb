# frozen_string_literal: true

module Collavre
  # Measures the latest completed attempt, excluding queue time and earlier retries.
  # Missing completion events (including external delegation) are not estimated.
  class TaskExecutionTime
    def self.seconds(task)
      return unless task.done?

      events = task.task_actions.where(action_type: %w[start completion])
        .order(created_at: :desc, id: :desc).pluck(:action_type, :created_at)
      return unless events.first&.first == "completion"

      started = events.find { |type, _time| type == "start" }
      return unless started

      events.first.last - started.last
    end
  end
end
