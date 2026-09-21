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

    # Auto-recover from transient DB contention. WebhooksController acks Linear
    # with 200 the instant it enqueues this job (ack-before-apply), so Linear
    # never re-delivers a payload once accepted. Without a retry, a transient
    # ActiveRecord::Deadlocked / LockWaitTimeout — which InboundApplier CAN hit,
    # since it takes `with_lock`/`lock!` on the same Creative the OUTBOUND worker
    # locks (see inbound_applier.rb's lock-order note) — would park the event as
    # a failed execution and the local mirror would silently diverge from Linear
    # with no resend to fix it. Retrying is safe: a deadlock/lock-timeout rolls
    # the whole transaction back (no partial apply), and InboundApplier is
    # idempotent (create no-ops on an existing link, unique indexes guard
    # duplicates, disposition checks refuse to clobber newer local edits), so a
    # re-run cannot double-apply. Scope is deliberately narrow — only transient
    # contention retries; a real bug still raises and parks (loud, operator-
    # visible) rather than looping. The wait is kept SHORT (much shorter than the
    # outbound jobs' polynomially_longer) so a rescheduled retry disturbs this
    # FIFO queue's receipt order as little as possible; the applier's own
    # out-of-order tolerance covers the small residual reordering.
    retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout,
             wait: 2.seconds, attempts: 5

    def perform(payload)
      unless CollavreLinear.const_defined?(:InboundApplier)
        Rails.logger.info(
          "[CollavreLinear::InboundApplyJob] InboundApplier not defined yet; skipping"
        )
        return
      end

      Collavre::Creatives::History.track(actor: nil, origin: :sync) do
        CollavreLinear::InboundApplier.new(payload).apply!
      end
    end
  end
end
