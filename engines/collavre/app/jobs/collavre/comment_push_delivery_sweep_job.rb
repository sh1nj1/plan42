# frozen_string_literal: true

module Collavre
  class CommentPushDeliverySweepJob < ApplicationJob
    queue_as :default

    def perform
      recoverable_deliveries.find_each do |delivery|
        delivery.enqueue_push!
      rescue StandardError => e
        Rails.logger.error(
          "[CommentPushDeliverySweepJob] Failed delivery #{delivery.id}: #{e.class}: #{e.message}"
        )
      end
    end

    private

    def recoverable_deliveries
      CommentNotificationDelivery.ready_for_push.or(
        CommentNotificationDelivery.where.not(workflow_execution_id: nil).where(push_state: Workflow::PushDelivery::STATES)
      )
    end
  end
end
