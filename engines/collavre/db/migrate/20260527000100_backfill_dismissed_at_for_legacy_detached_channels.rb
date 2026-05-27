class BackfillDismissedAtForLegacyDetachedChannels < ActiveRecord::Migration[8.1]
  # Chips are now rendered via `not_dismissed` (dismissed_at IS NULL) instead
  # of `state = active`. Without a backfill, any channel that was already
  # detached pre-upgrade — user clicked X under the old flow, or the PR auto-
  # detached on close — would reappear as a chip with the default-open badge
  # the first time the new view runs. Mark legacy detached rows as dismissed
  # using their last-touched timestamp as a best-effort dismissed_at.
  #
  # Idempotent: the WHERE clause skips rows that already have dismissed_at.
  def up
    execute <<~SQL.squish
      UPDATE channels
      SET dismissed_at = COALESCE(updated_at, CURRENT_TIMESTAMP)
      WHERE state = 1 AND dismissed_at IS NULL
    SQL
  end

  def down
    # No-op: we can't distinguish backfilled rows from rows the user actually
    # dismissed at the exact same timestamp, and leaving dismissed_at populated
    # on rollback is harmless.
  end
end
