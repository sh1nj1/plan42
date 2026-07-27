module CollavreGithub
  # Idempotency ledger for inbound GitHub webhook deliveries, keyed by the
  # `X-GitHub-Delivery` GUID.
  #
  # Two independent duplicate sources exist and both reuse the same GUID:
  #   1. Multiple hooks on one repo (e.g. one per deployed instance sharing this
  #      database) — GitHub fans the same delivery out to every hook URL.
  #   2. GitHub redelivery after a 5xx/timeout.
  # A single UNIQUE claim on the GUID collapses both.
  class WebhookDelivery < ApplicationRecord
    self.table_name = "github_webhook_deliveries"

    # Rows only exist to answer "have I seen this GUID?" — an updated_at column
    # would never be written.
    self.record_timestamps = false

    RETENTION = 7.days

    # How long a claim may sit unprocessed before another delivery of the same
    # GUID is allowed to take it over. `WebhooksController` releases its claim
    # on any exception the process survives, so this window only covers a
    # request that died without running its rescue — SIGKILL, an OOM, a worker
    # timeout. Without the takeover such a GUID would answer 200 forever and
    # the operator's Redeliver button would silently do nothing.
    STALE_CLAIM_AFTER = 5.minutes

    validates :delivery_guid, presence: true

    # Claims the delivery for this process. Returns true when the caller owns
    # the delivery and should process it, false when another request (another
    # hook, or a redelivery) already claimed it.
    #
    # A blank GUID means the request did not come from GitHub's delivery
    # pipeline (hand-crafted request, legacy test client). There is nothing to
    # deduplicate on, so it is allowed through rather than silently dropped —
    # dropping would turn every unlabelled delivery into a no-op.
    def self.claim(delivery_guid, event: nil)
      return true if delivery_guid.blank?

      create!(delivery_guid: delivery_guid, event: event, created_at: Time.current)
      true
    rescue ActiveRecord::RecordNotUnique
      reclaim_stale(delivery_guid, event: event)
    end

    # Takes over an abandoned claim. A row on its own does not prove the
    # delivery was handled — only `processed_at` does — so an unprocessed row
    # older than STALE_CLAIM_AFTER is treated as owner-less.
    #
    # Concurrent takeovers resolve to one winner without extra locking: the
    # UPDATE takes a row lock, and the loser re-evaluates its WHERE against the
    # committed row, whose `created_at` is no longer stale, so it matches
    # nothing and reports the delivery as a duplicate.
    def self.reclaim_stale(delivery_guid, event: nil)
      where(delivery_guid: delivery_guid, processed_at: nil)
        .where(created_at: ...STALE_CLAIM_AFTER.ago)
        .update_all(created_at: Time.current, event: event)
        .positive?
    end

    # Marks a claim as genuinely handled. Only after this does a redelivery of
    # the same GUID get dismissed as a duplicate.
    def self.mark_processed!(delivery_guid)
      return if delivery_guid.blank?

      where(delivery_guid: delivery_guid).update_all(processed_at: Time.current)
    end

    # Drops a claim whose run failed so the redelivery is processed instead of
    # dismissed. Scoped to unprocessed rows: a failure arriving after a
    # successful run must never erase that run's record.
    def self.release(delivery_guid)
      return if delivery_guid.blank?

      where(delivery_guid: delivery_guid, processed_at: nil).delete_all
    end

    # Called from the recurring prune job. Deliveries older than RETENTION can
    # no longer be redelivered by GitHub (its redelivery window is far shorter),
    # so keeping them only grows the table.
    def self.prune!(older_than: RETENTION.ago)
      where(created_at: ...older_than).delete_all
    end
  end
end
