# frozen_string_literal: true

module Collavre
  class CommentPushDeliverySweepJob < ApplicationJob
    queue_as :default

    def perform
      CommentNotificationDelivery.ready_for_push.find_each do |delivery|
        delivery.enqueue_push!
      rescue StandardError => e
        Rails.logger.error(
          "[CommentPushDeliverySweepJob] Failed delivery #{delivery.id}: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
