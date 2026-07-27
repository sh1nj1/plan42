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

    # Claims the delivery for this process. Returns an ownership token when the
    # caller owns the delivery and should process it, nil when another request
    # (another hook, or a redelivery) already claimed it.
    #
    # The token, not the GUID, is what `release` and `mark_processed!` act on.
    # Ownership is not permanent — a run that outlives STALE_CLAIM_AFTER has its
    # claim taken over — so a caller that acted on the GUID alone would reach
    # past its own claim and disturb the run that replaced it.
    #
    # A blank GUID means the request did not come from GitHub's delivery
    # pipeline (hand-crafted request, legacy test client). There is nothing to
    # deduplicate on, so it is allowed through rather than silently dropped —
    # dropping would turn every unlabelled delivery into a no-op. UNTRACKED
    # keeps the caller's contract uniform: it is truthy, and the GUID-blank
    # guard in `release`/`mark_processed!` makes both a no-op for it.
    UNTRACKED = "untracked".freeze

    def self.claim(delivery_guid, event: nil)
      return UNTRACKED if delivery_guid.blank?

      insert_claim(delivery_guid, event)
    end

    # Resolves a collision on the UNIQUE index. Three things can be true of the
    # row that beat us to it:
    #
    #   - it is stale, and `reclaim_stale` takes it over;
    #   - it is live, so this delivery genuinely is a duplicate;
    #   - it is GONE, because the request holding it failed and called
    #     `release` between our INSERT and this lookup. Reporting a duplicate
    #     then would lose the event outright — that request has already given
    #     up, so nobody would process it — which is the very outcome the
    #     ledger exists to prevent. The insert is retried instead.
    #
    # One retry suffices: it only has to cover the window opened by that single
    # release, and bounding it keeps a pathological loop of releases from
    # spinning here forever.
    def self.insert_claim(delivery_guid, event, retried: false)
      token = SecureRandom.uuid
      create!(
        delivery_guid: delivery_guid,
        event: event,
        claim_token: token,
        created_at: Time.current
      )
      token
    rescue ActiveRecord::RecordNotUnique
      reclaimed = reclaim_stale(delivery_guid, event: event)
      return reclaimed if reclaimed
      return nil if retried || exists?(delivery_guid: delivery_guid)

      insert_claim(delivery_guid, event, retried: true)
    end
    private_class_method :insert_claim

    # Takes over an abandoned claim. A row on its own does not prove the
    # delivery was handled — only `processed_at` does — so an unprocessed row
    # older than STALE_CLAIM_AFTER is treated as owner-less.
    #
    # Concurrent takeovers resolve to one winner without extra locking: the
    # UPDATE takes a row lock, and the loser re-evaluates its WHERE against the
    # committed row, whose `created_at` is no longer stale, so it matches
    # nothing and reports the delivery as a duplicate.
    #
    # The takeover issues a FRESH token, which is what strips ownership from the
    # run being replaced: its own `release`/`mark_processed!` no longer match.
    def self.reclaim_stale(delivery_guid, event: nil)
      token = SecureRandom.uuid
      updated = where(delivery_guid: delivery_guid, processed_at: nil)
        .where(created_at: ...STALE_CLAIM_AFTER.ago)
        .update_all(created_at: Time.current, event: event, claim_token: token)

      token if updated.positive?
    end

    # Marks a claim as genuinely handled. Only after this does a redelivery of
    # the same GUID get dismissed as a duplicate.
    #
    # Scoped to the token: if this run was superseded while it worked, the row
    # now belongs to its replacement and must not be stamped processed on its
    # behalf — the replacement is still running and has yet to earn that.
    def self.mark_processed!(delivery_guid, token)
      return if delivery_guid.blank? || token.blank?

      where(delivery_guid: delivery_guid, claim_token: token)
        .update_all(processed_at: Time.current)
    end

    # Drops a claim whose run failed so the redelivery is processed instead of
    # dismissed.
    #
    # Scoped to the token as well as to unprocessed rows. Unprocessed alone was
    # not enough: a run slower than STALE_CLAIM_AFTER has already lost the row
    # to a replacement, and deleting on the GUID would have taken the
    # replacement's live claim with it — freeing the GUID for a third request
    # to claim while the replacement was still running, and leaving the
    # replacement's own `mark_processed!` with no row to stamp, so every later
    # redelivery would repeat the event.
    def self.release(delivery_guid, token)
      return if delivery_guid.blank? || token.blank?

      where(delivery_guid: delivery_guid, claim_token: token, processed_at: nil).delete_all
    end

    # Called from the recurring prune job. Deliveries older than RETENTION can
    # no longer be redelivered by GitHub (its redelivery window is far shorter),
    # so keeping them only grows the table.
    def self.prune!(older_than: RETENTION.ago)
      where(created_at: ...older_than).delete_all
    end
  end
end
