# frozen_string_literal: true

module Collavre
  module ActivityLogsHelper
    def inline_task_execution_time(task)
      seconds = TaskExecutionTime.seconds(task) if task
      format_execution_time(seconds) if seconds
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
