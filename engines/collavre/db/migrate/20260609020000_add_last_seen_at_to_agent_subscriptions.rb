# frozen_string_literal: true

# Liveness heartbeat column for Claude Channel presence rows. Rows are only
# deleted by AgentChannel#unsubscribed, so a Puma/ActionCable crash or deploy
# orphans a row — and presence-gated routing would then stay active forever,
# dispatching into a dead stream. last_seen_at is refreshed by the channel's
# periodic heartbeat; a row whose last_seen_at is older than the staleness
# window is treated as dead (ignored by the live scope, reaped opportunistically).
class AddLastSeenAtToAgentSubscriptions < ActiveRecord::Migration[8.0]
  def up
    add_column :agent_subscriptions, :last_seen_at, :datetime
    # Backfill existing rows from created_at so a row written before this
    # migration is considered live until its next heartbeat (or stale-reap).
    execute "UPDATE agent_subscriptions SET last_seen_at = created_at WHERE last_seen_at IS NULL"
    change_column_null :agent_subscriptions, :last_seen_at, false
    add_index :agent_subscriptions, :last_seen_at
  end

  def down
    remove_index :agent_subscriptions, :last_seen_at
    remove_column :agent_subscriptions, :last_seen_at
  end
end
