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
    # Inbound webhooks MUST apply in receipt order: a Comment can arrive before
    # its issue's Create, and an Update before its Create. Running these on a
    # multi-threaded queue lets workers apply them out of order — the comment
    # then finds no IssueLink and is dropped. `linear_inbound` is served by a
    # single-thread, single-process worker (config/queue.yml), making it a
    # sequential FIFO queue that preserves enqueue (receipt) order.
    queue_as :linear_inbound

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
