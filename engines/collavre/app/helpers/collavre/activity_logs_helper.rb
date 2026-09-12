# frozen_string_literal: true

module Collavre
  module ActivityLogsHelper
    def task_execution_time(task)
      return t("collavre.comments.activity_logs.in_progress") if task.active?

      seconds = TaskExecutionTime.seconds(task)
      return t("collavre.comments.activity_logs.unavailable") unless seconds

      format_execution_time(seconds)
    end

    def format_execution_time(seconds)
      days, remainder = seconds.round.divmod(86400)
      hours, remainder = remainder.divmod(3600)
      minutes, seconds = remainder.divmod(60)
      units = { days: days, hours: hours, minutes: minutes, seconds: seconds }
      units.filter_map do |unit, count|
        next if count.zero? && (unit != :seconds || units.values.any?(&:positive?))

        t("collavre.comments.activity_logs.#{unit}", count: count)
      end.join(" ")
    end
  end
end
