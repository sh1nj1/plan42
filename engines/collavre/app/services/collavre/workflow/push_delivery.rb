# frozen_string_literal: true

module Collavre
  module Workflow
    # Workflow queue and transport ownership are independent of ordinary push.
    class PushDelivery
      QUEUE_TIMEOUT = 30.minutes
      TRANSPORT_TIMEOUT = 5.minutes
      MAX_ATTEMPTS = 3
      STATES = %w[pending enqueued delivering].freeze

      def self.ready(scope)
        pending = scope.where(push_state: "pending", push_claim_token: nil)
        queue = scope.where(push_state: %w[pending enqueued]).where("push_claimed_at <= ?", QUEUE_TIMEOUT.ago)
        transport = scope.where(push_state: "delivering").where("push_claimed_at <= ?", TRANSPORT_TIMEOUT.ago)
        pending.or(queue).or(transport)
      end

      def initialize(delivery)
        @delivery = delivery
      end

      def enqueue!
        @delivery.reload
        return false unless STATES.include?(@delivery.push_state)
        return suppress if denied?
        token = claim!
        return false unless token
        job = WorkflowPushJob.perform_later(@delivery.id, token)
        raise ActiveJob::EnqueueError unless job && job.successfully_enqueued?
        matching(token, "pending").update_all(push_state: "enqueued", push_enqueued_at: Time.current)
        true
      rescue StandardError => error
        retry_or_fail(token, "pending") if token
        Rails.logger.warn("[Workflow] delivery_id=#{@delivery.id} enqueue_error=#{error.class.name}")
        false
      end

      def perform!(token)
        claimed = matching(token, %w[pending enqueued]).where("push_claimed_at > ?", QUEUE_TIMEOUT.ago)
          .update_all(push_state: "delivering", push_claimed_at: Time.current)
        return unless claimed == 1
        @delivery.reload
        return finish(token, "suppressed") if denied?
        PushNotificationJob.perform_now(@delivery.recipient_id, message: @delivery.message,
          link: @delivery.link, title: @delivery.title)
        finish(token, "completed")
      rescue StandardError => error
        retry_or_fail(token, "delivering")
        Rails.logger.warn("[Workflow] delivery_id=#{@delivery.id} transport_error=#{error.class.name}")
      end

      private

      def scope = CommentNotificationDelivery.where(id: @delivery.id)

      def matching(token, state)
        scope.where(push_claim_token: token, push_state: state)
      end

      def denied?
        execution = Execution.find_by(id: @delivery.workflow_execution_id)
        return true unless execution && execution.reason == "human_handoff"
        safety = Safety.new(execution)
        owner = safety.owner
        safety.reason.present? || !owner || owner.id != execution.owner_id || owner.id != @delivery.recipient_id ||
          owner.notifications_enabled == false
      end

      def suppress
        scope.where(push_state: STATES).update_all(push_state: "suppressed", push_claim_token: nil, push_claimed_at: nil)
        false
      end

      def claim!
        ready = self.class.ready(scope)
        exhausted = ready.where("push_attempts >= ?", MAX_ATTEMPTS)
        exhausted.update_all(push_state: "failed", push_claim_token: nil, push_claimed_at: nil)
        token = SecureRandom.uuid
        updated = ready.where("push_attempts < ?", MAX_ATTEMPTS).update_all(
          [ "push_state = ?, push_claim_token = ?, push_claimed_at = ?, push_attempts = push_attempts + 1", "pending", token, Time.current ])
        token if updated == 1
      end

      def finish(token, state)
        matching(token, "delivering").where("push_claimed_at > ?", TRANSPORT_TIMEOUT.ago)
          .update_all(push_state: state, push_claim_token: nil, push_claimed_at: nil)
      end

      def retry_or_fail(token, state)
        timeout = state == "delivering" ? TRANSPORT_TIMEOUT : QUEUE_TIMEOUT
        matching(token, state).where("push_claimed_at > ?", timeout.ago).update_all(
          [ "push_state = CASE WHEN push_attempts >= ? THEN 'failed' ELSE 'pending' END, push_claim_token = NULL, push_claimed_at = NULL", MAX_ATTEMPTS ])
      end
    end
  end
end
