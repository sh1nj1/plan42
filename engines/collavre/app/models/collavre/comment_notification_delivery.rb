# frozen_string_literal: true

module Collavre
  class CommentNotificationDelivery < ApplicationRecord
    self.table_name = "comment_notification_deliveries"

    CLAIM_TIMEOUT = 5.minutes

    validates :delivery_key, :recipient_id, :message, presence: true

    scope :ready_for_push, -> {
      ordinary = where(workflow_execution_id: nil, push_enqueued_at: nil)
        .where("push_claimed_at IS NULL OR push_claimed_at < ?", CLAIM_TIMEOUT.ago)
      ordinary.or(Workflow::PushDelivery.ready(where.not(workflow_execution_id: nil)))
    }

    def enqueue_push!
      return Workflow::PushDelivery.new(self).enqueue! if workflow_execution_id

      enqueue_ordinary_push!
    end

    def enqueue_ordinary_push!
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
      enqueue_succeeded = job && (!job.respond_to?(:successfully_enqueued?) || job.successfully_enqueued?)
      unless enqueue_succeeded
        enqueue_error = job.respond_to?(:enqueue_error) ? job.enqueue_error : nil
        raise enqueue_error || ActiveJob::EnqueueError.new("Push notification enqueue failed")
      end

      acknowledge_ordinary_push!(claim_token)

      true
    rescue StandardError
      release_claim(claim_token)
      raise
    end

    private

    def acknowledge_ordinary_push!(claim_token)
      acknowledged = self.class
        .where(id: id, push_claim_token: claim_token, push_enqueued_at: nil)
        .update_all(
          push_enqueued_at: Time.current,
          push_claim_token: nil,
          push_claimed_at: nil,
          updated_at: Time.current
        )
      raise ActiveRecord::StaleObjectError.new(self, "enqueue push") unless acknowledged == 1
    end

    def release_claim(claim_token)
      self.class.where(id: id, push_claim_token: claim_token).update_all(
        push_claim_token: nil,
        push_claimed_at: nil,
        updated_at: Time.current
      )
    end
  end
end
