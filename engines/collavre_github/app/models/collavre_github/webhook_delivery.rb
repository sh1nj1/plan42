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
      false
    end

    # Called from the recurring prune job. Deliveries older than RETENTION can
    # no longer be redelivered by GitHub (its redelivery window is far shorter),
    # so keeping them only grows the table.
    def self.prune!(older_than: RETENTION.ago)
      where(created_at: ...older_than).delete_all
    end
  end
end
