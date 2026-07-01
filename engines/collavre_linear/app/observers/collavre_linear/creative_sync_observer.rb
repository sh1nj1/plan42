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

      # Transient storage for archive data captured before the row is gone.
      attr_accessor :_linear_archive_issue_id, :_linear_archive_account_id

      # Transient flag: did the just-committed save touch a Linear-relevant
      # column? Captured in after_save (where saved_changes is reliable) so the
      # after_commit hook can short-circuit WITHOUT a DB query. saved_changes is
      # cleared by the time after_commit runs (esp. under transactional tests),
      # so it cannot be read there directly.
      attr_accessor :_linear_relevant_change

      # Transient flag: did this save re-parent the creative (parent_id change)?
      # A move carries its whole subtree, but the core move hook touches
      # descendants via `update_all` (no callbacks fire on them), so their sync
      # must be fanned out from the moved root. Same capture-in-after_save reason
      # as above.
      attr_accessor :_linear_parent_changed

      # prepend: true ensures we run before the dependent: :destroy cascade that
      # deletes IssueLinks — which is added by a separate engine initializer.
      before_destroy :capture_linear_archive_info, prepend: true
      after_save :capture_linear_relevant_change
      after_commit :enqueue_linear_outbound_sync
    end

    private

    # Capture linear_issue_id and account_id before the creative (and its
    # dependent IssueLink) are deleted from the DB.  Stored in transient attrs
    # so the after_commit destroy branch can read them without hitting a gone row.
    def capture_linear_archive_info
      issue_link = linear_issue_links.first
      return unless issue_link

      self._linear_archive_issue_id  = issue_link.linear_issue_id
      self._linear_archive_account_id = issue_link.project_link.account_id
    rescue StandardError => e
      Rails.logger.error(
        "[CollavreLinear::CreativeSyncObserver] before_destroy capture failed for " \
        "creative #{id}: #{e.class}: #{e.message}"
      )
    end

    # Columns whose change can alter the exported Linear issue (mirrors what
    # CreativeExporter hashes: description -> title/description, sequence ->
    # priority, data -> state/labels) plus parent_id (re-parenting -> parentId).
    LINEAR_RELEVANT_COLUMNS = %w[description sequence data parent_id].freeze

    # Record — in after_save, where saved_changes is reliable — whether this
    # save touched a Linear-relevant column. A create always counts (its seeded
    # attributes populate the whole row).
    def capture_linear_relevant_change
      self._linear_relevant_change =
        if previously_new_record?
          true
        else
          (saved_changes.keys & LINEAR_RELEVANT_COLUMNS).any?
        end
      self._linear_parent_changed = saved_change_to_parent_id?
    end

    def enqueue_linear_outbound_sync
      return if skip_linear_sync

      # Destroys are driven ENTIRELY by what before_destroy captured. By the time
      # this after_commit runs, the ProjectLink/IssueLink rows are already gone
      # via dependent: :destroy, so `linked_subtree?` is unreliable here — it
      # returns false for the link OWNER itself, which would otherwise swallow
      # the captured archive id and leak a live Linear issue. Trust the captured
      # ids; enqueue_archive_if_captured no-ops when nothing was captured (an
      # unlinked creative), so this is safe for every destroy.
      if destroyed?
        enqueue_archive_if_captured
        return
      end

      # Cheap in-memory short-circuit BEFORE any DB work: `after_commit` fires for
      # every Creative write app-wide. An update/create with no Linear-relevant
      # column change can't affect the exported issue, so skip the subtree query.
      return if relevant_change_absent?
      return unless linked_subtree?

      mark_issue_link_dirty

      # A re-parent moves this creative's whole subtree into the linked root, but
      # the core move hook only `update_all`-touches descendants (no callbacks),
      # so they never enqueue themselves. Fan out to each so pre-existing children
      # reach Linear too. Per-creative jobs self-order via the exporter's
      # ParentNotExportedError retry, so enqueue order doesn't matter. Non-move
      # changes (description/data/sequence) only affect this one creative.
      target_ids = _linear_parent_changed ? self_and_descendants.ids : [ id ]
      target_ids.each { |cid| CollavreLinear::OutboundSyncJob.perform_later(cid) }
    rescue StandardError => e
      # Never let a sync-scheduling failure break the host transaction's
      # commit callbacks.
      Rails.logger.error(
        "[CollavreLinear::CreativeSyncObserver] failed to enqueue sync for " \
        "creative #{id}: #{e.class}: #{e.message}"
      )
    end

    # True when this commit touched no Linear-relevant column. Only reached for
    # non-destroy commits (destroys return early via the archive path). Reads
    # the flag captured in after_save; a nil flag (no save ran, e.g. a bare
    # touch) is treated as "no relevant change".
    def relevant_change_absent?
      !_linear_relevant_change
    end

    def enqueue_archive_if_captured
      return unless _linear_archive_issue_id && _linear_archive_account_id

      CollavreLinear::OutboundArchiveJob.perform_later(
        _linear_archive_issue_id,
        _linear_archive_account_id
      )
    end

    # Mark the IssueLink dirty so the exporter knows a sync is pending.
    # Only applicable when a link already exists; new creatives have no link yet
    # (linear_issue_id is NOT NULL so a link cannot be created before the API call).
    def mark_issue_link_dirty
      issue_link = linear_issue_links.first
      issue_link&.update_column(:sync_state, CollavreLinear::IssueLink.sync_states[:dirty])
    end

    # True when this creative (or any ancestor) carries a ProjectLink, i.e. it
    # lives inside a subtree that is linked to a Linear project. Only called for
    # non-destroy commits — the row is still present, so `self_and_ancestors` is
    # queryable.
    def linked_subtree?
      ancestor_ids = self_and_ancestors.pluck(:id)
      return false if ancestor_ids.empty?

      CollavreLinear::ProjectLink.where(creative_id: ancestor_ids).exists?
    end
  end
end
