# frozen_string_literal: true

module Collavre
  # Presence record for one live Claude Channel session subscription on the
  # per-agent ActionCable stream. The set of LIVE rows for an agent_id is the
  # authority for whether Claude Channel dispatch is active: a human's
  # concurrent sessions share one agent, so dispatch stays on while ANY session
  # holds a live row, and turns off when the last one is gone.
  #
  # Liveness is leased, not assumed. Rows are deleted only by
  # AgentChannel#unsubscribed, so a Puma/ActionCable crash or deploy orphans a
  # row. last_seen_at is refreshed by the channel's periodic heartbeat; a row
  # whose last_seen_at falls outside STALE_AFTER is dead — ignored by the live
  # scope so it cannot keep dispatch active, and reaped opportunistically on the next
  # subscribe/unsubscribe for the agent.
  class AgentSubscription < ApplicationRecord
    self.table_name = "agent_subscriptions"

    belongs_to :agent, class_name: Collavre.configuration.user_class_name

    # Heartbeat cadence (see AgentChannel#subscribe_to_agent_stream). STALE_AFTER
    # is a multiple of it so a single missed beat (GC pause, brief stall) does
    # not flap a live session to "dead".
    HEARTBEAT_SECONDS = 15
    STALE_AFTER = 45.seconds

    before_validation :ensure_last_seen_at, on: :create

    scope :live, -> { where(arel_table[:last_seen_at].gt(STALE_AFTER.ago)) }
    scope :stale, -> { where(arel_table[:last_seen_at].lteq(STALE_AFTER.ago)) }

    # Refresh the heartbeat for one session's row. No-op if the row is already
    # gone (a newer subscribe rotated it, or it was reaped) — the periodic
    # callback must not resurrect a removed presence row.
    def self.touch!(agent_id, token)
      where(agent_id: agent_id, token: token).update_all(last_seen_at: Time.current)
    end

    # Drop crash-orphaned rows for an agent so a plain presence check is
    # accurate. Scoped to one agent_id: cheap, and called on the agent's own
    # subscribe/unsubscribe path.
    def self.reap_stale!(agent_id)
      stale.where(agent_id: agent_id).delete_all
    end

    private

    def ensure_last_seen_at
      self.last_seen_at ||= Time.current
    end
  end
end
