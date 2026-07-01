# frozen_string_literal: true

module CollavreLinear
  # Applies a verified inbound Linear webhook payload to local state.
  #
  # Usage:
  #   CollavreLinear::InboundApplyJob.perform_later(payload)
  #
  # Signature verification, timestamp/replay checks, and echo suppression all
  # happen in WebhooksController BEFORE this job is enqueued. By the time we run,
  # the payload is trusted.
  #
  # The heavy lifting lives in CollavreLinear::InboundApplier (Task 10). Until
  # that constant exists, this job no-ops gracefully so the webhook pipeline can
  # ship and be validated independently.
  class InboundApplyJob < ApplicationJob
    queue_as :default

    def perform(payload)
      unless CollavreLinear.const_defined?(:InboundApplier)
        Rails.logger.info(
          "[CollavreLinear::InboundApplyJob] InboundApplier not defined yet; skipping"
        )
        return
      end

      CollavreLinear::InboundApplier.new(payload).apply!
    end
  end
end
