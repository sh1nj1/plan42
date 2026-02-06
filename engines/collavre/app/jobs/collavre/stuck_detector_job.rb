# frozen_string_literal: true

module Collavre
  # StuckDetectorJob runs periodically to detect stuck tasks and creatives.
  #
  # This job should be scheduled to run every 5-10 minutes via cron or similar.
  #
  # Usage:
  #   StuckDetectorJob.perform_later
  #
  # To schedule with SolidQueue:
  #   # config/recurring.yml
  #   stuck_detector:
  #     class: Collavre::StuckDetectorJob
  #     schedule: every 10 minutes
  #
  class StuckDetectorJob < ApplicationJob
    queue_as :default

    def perform
      detector = Orchestration::StuckDetector.new
      result = detector.detect_and_escalate

      if result.escalated_count > 0
        Rails.logger.info(
          "[StuckDetectorJob] Detected #{result.stuck_items.count} stuck items, " \
          "escalated #{result.escalated_count}"
        )
      end

      result
    end
  end
end
