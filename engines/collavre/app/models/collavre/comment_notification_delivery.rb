# frozen_string_literal: true

module Collavre
  class CommentNotificationDelivery < ApplicationRecord
    self.table_name = "comment_notification_deliveries"

    CLAIM_TIMEOUT = 5.minutes

    validates :delivery_key, :recipient_id, :message, presence: true

    scope :ready_for_push, -> {
      where(push_enqueued_at: nil)
        .where("push_claimed_at IS NULL OR push_claimed_at < ?", CLAIM_TIMEOUT.ago)
    }

    def enqueue_push!
      claim_token = SecureRandom.uuid
      claimed_at = Time.current
      claimed = self.class.ready_for_push
                          .where(id: id)
                          .update_all(
                            push_claim_token: claim_token,
                            push_claimed_at: claimed_at,
                            updated_at: claimed_at
                          )
      return false unless claimed == 1

      job = PushNotificationJob.perform_later(recipient_id, message: message, link: link)
      if job.respond_to?(:successfully_enqueued?) && !job.successfully_enqueued?
        enqueue_error = job.enqueue_error || ActiveJob::EnqueueError.new("Push notification enqueue failed")
        raise enqueue_error
      end

      acknowledged = self.class
        .where(id: id, push_claim_token: claim_token, push_enqueued_at: nil)
        .update_all(
          push_enqueued_at: Time.current,
          push_claim_token: nil,
          push_claimed_at: nil,
          updated_at: Time.current
        )
      raise ActiveRecord::StaleObjectError.new(self, "enqueue push") unless acknowledged == 1

      true
    rescue StandardError
      release_claim(claim_token)
      raise
    end

    private

    def release_claim(claim_token)
      self.class.where(id: id, push_claim_token: claim_token).update_all(
        push_claim_token: nil,
        push_claimed_at: nil,
        updated_at: Time.current
      )
    end
  end
end
