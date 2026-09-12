# frozen_string_literal: true

module Collavre
  # Measures the latest completed attempt, excluding queue time and earlier retries.
  # Missing completion events are not estimated, including historical delegations.
  class TaskExecutionTime
    def self.seconds(task)
      return unless task.done?

      events = execution_events(task)
      return unless events.first&.first == "completion"

      # Each start marks a new attempt, even when the preceding attempt has no terminal event.
      started = events.find { |type, _time| type == "start" }
      return unless started

      events.first.last - started.last
    end

    def self.execution_events(task)
      actions = task.task_actions
      unless actions.loaded?
        return actions.where(action_type: %w[start completion])
          .order(created_at: :desc, id: :desc).pluck(:action_type, :created_at)
      end

      actions.select { |action| action.action_type.in?(%w[start completion]) }
        .sort_by { |action| [ action.created_at, action.id ] }.reverse
        .map { |action| [ action.action_type, action.created_at ] }
    end
    private_class_method :execution_events
  end
end
