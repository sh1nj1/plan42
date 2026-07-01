# frozen_string_literal: true

module CollavreLinear
  # Auto-triggers an outbound Linear sync whenever a Collavre::Creative inside a
  # linked subtree is created, updated, moved, or destroyed.
  #
  # Mixed into Collavre::Creative via the engine's `to_prepare` block:
  #
  #   Collavre::Creative.include CollavreLinear::CreativeSyncObserver
  #
  # which registers `after_commit` and adds the transient `skip_linear_sync`
  # accessor.
  #
  # Loop guard: the inbound applier (Task 10) sets `creative.skip_linear_sync =
  # true` on records it mutates so the resulting after_commit does NOT bounce a
  # change back to Linear. The flag is a per-record transient attribute (not
  # persisted), so it only suppresses the single in-memory instance that applied
  # the inbound change.
  module CreativeSyncObserver
    extend ActiveSupport::Concern

    included do
      # Transient, per-record suppression flag used by the inbound applier.
      attr_accessor :skip_linear_sync

      after_commit :enqueue_linear_outbound_sync
    end

    private

    def enqueue_linear_outbound_sync
      return if skip_linear_sync
      return unless linked_subtree?

      CollavreLinear::OutboundSyncJob.perform_later(id)
    rescue StandardError => e
      # Never let a sync-scheduling failure break the host transaction's
      # commit callbacks.
      Rails.logger.error(
        "[CollavreLinear::CreativeSyncObserver] failed to enqueue sync for " \
        "creative #{id}: #{e.class}: #{e.message}"
      )
    end

    # True when this creative (or any ancestor) carries a ProjectLink, i.e. it
    # lives inside a subtree that is linked to a Linear project.
    #
    # On destroy the row is already gone, so `self_and_ancestors` cannot be
    # queried; fall back to the in-memory parent chain via cached ancestor ids.
    def linked_subtree?
      ancestor_ids = linked_subtree_ancestor_ids
      return false if ancestor_ids.empty?

      CollavreLinear::ProjectLink.where(creative_id: ancestor_ids).exists?
    end

    def linked_subtree_ancestor_ids
      if destroyed?
        # Row is gone; walk the persisted hierarchy is impossible, so use the
        # in-memory parent_id and its ancestors resolved through a fresh lookup
        # of the (still-present) parent.
        ids = [id]
        pid = parent_id
        while pid
          ids << pid
          parent = self.class.find_by(id: pid)
          break unless parent

          pid = parent.parent_id
        end
        ids
      else
        self_and_ancestors.pluck(:id)
      end
    end
  end
end
