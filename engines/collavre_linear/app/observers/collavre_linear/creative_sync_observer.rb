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
    end

    def enqueue_linear_outbound_sync
      return if skip_linear_sync
      # Cheap in-memory short-circuit BEFORE any DB work: `after_commit` fires for
      # every Creative write app-wide. Destroys always proceed (archive path);
      # an update/create with no Linear-relevant column change can't affect the
      # exported issue, so skip the subtree query entirely.
      return if relevant_change_absent?
      return unless linked_subtree?

      if destroyed?
        enqueue_archive_if_captured
      else
        mark_issue_link_dirty
        CollavreLinear::OutboundSyncJob.perform_later(id)
      end
    rescue StandardError => e
      # Never let a sync-scheduling failure break the host transaction's
      # commit callbacks.
      Rails.logger.error(
        "[CollavreLinear::CreativeSyncObserver] failed to enqueue sync for " \
        "creative #{id}: #{e.class}: #{e.message}"
      )
    end

    # True when this commit touched no Linear-relevant column. Destroys never
    # short-circuit (handled via the archive path). Otherwise read the flag
    # captured in after_save. A nil flag (no save ran, e.g. a bare touch) is
    # treated as "no relevant change".
    def relevant_change_absent?
      return false if destroyed?

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
        ids = [ id ]
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
