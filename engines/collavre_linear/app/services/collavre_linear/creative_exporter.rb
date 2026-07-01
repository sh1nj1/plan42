# frozen_string_literal: true

require "digest"

module CollavreLinear
  # Syncs a single Collavre::Creative to Linear as an issue.
  #
  # Usage:
  #   CollavreLinear::CreativeExporter.new(creative).sync!
  #
  # Resolves the governing ProjectLink from the creative itself or its nearest
  # ancestor. Creates a new Linear issue and IssueLink on first run; updates the
  # existing issue on subsequent runs.  Skips the network call when the content
  # hash is unchanged (dirty-tracking).  Raises Client::Error on network failure
  # so the caller (OutboundSyncJob) can retry.
  class CreativeExporter
    # Raised when a child must be exported AFTER its parent's Linear issue
    # exists but the parent hasn't been exported yet (independent per-creative
    # jobs can run out of order under multiple queue workers). The job catches
    # this and re-enqueues so the child retries once the parent has landed —
    # without this, the child would be created as a TOP-LEVEL Linear issue and
    # the tree would be permanently flattened on first export.
    class ParentNotExportedError < StandardError; end

    # Thin adapter so FieldMapper's #title contract is met without touching core.
    # Collavre::Creative has no :title column — we derive it from creative_snippet
    # (plain-text truncation of the description used everywhere in the app).
    CreativeAdapter = Struct.new(:title, :description, :sequence, :data, keyword_init: true)

    # Compute the outbound content hash for a Creative's current state. Shared
    # with the inbound applier so it can advance IssueLink#content_hash after
    # applying a remote update, keeping the exporter's dirty-check consistent.
    #
    # The hash folds in the parent's linear_issue_id so that a pure reparent
    # (content fields unchanged) still changes the hash and drives update_issue!,
    # which pushes the new parentId to Linear. Otherwise Collavre and Linear
    # hierarchies would diverge after a move.
    def self.content_hash_for(creative)
      attrs = FieldMapper.creative_to_issue_attrs(
        CreativeAdapter.new(
          title:       creative.creative_snippet,
          description: creative.description,
          sequence:    creative.sequence,
          data:        creative.data
        )
      )
      hash_attrs(attrs, parent_linear_issue_id_for(creative))
    end

    # Resolve the parent Creative's linked linear_issue_id (or nil when the
    # parent is absent or not itself linked to a Linear issue).
    def self.parent_linear_issue_id_for(creative)
      parent = creative.parent
      return nil unless parent

      parent.linear_issue_links.first&.linear_issue_id
    end

    # SHA-256 of the sorted, serialised mapped attrs plus the parent's linear
    # issue id (stable key order). Single source of truth so inbound + outbound
    # and the class/instance paths all agree.
    def self.hash_attrs(attrs, parent_linear_issue_id)
      payload = attrs.merge(_parent_linear_issue_id: parent_linear_issue_id)
      Digest::SHA256.hexdigest(payload.sort.to_h.to_json)
    end

    def initialize(creative)
      @creative = creative
    end

    def sync!
      project_link = resolve_project_link
      return unless project_link

      account   = project_link.account
      client    = Client.new(account)
      attrs     = FieldMapper.creative_to_issue_attrs(adapt(@creative))
      parent_id = parent_linear_issue_id
      hash      = compute_content_hash(attrs, parent_id)

      issue_link = @creative.linear_issue_links.first

      # Ordering guard for BOTH create and update: if this creative's parent
      # belongs to the exported subtree but has not yet produced its Linear issue,
      # defer (the job re-enqueues on ParentNotExportedError once the parent lands).
      #   - create: exporting now would make a top-level issue, flattening the tree.
      #   - update: an already-linked creative moved under a NEWLY-created parent
      #     can run before the parent's create job. Without waiting we'd send no
      #     parentId, persist parent_issue_id for the still-nil parent, and the
      #     later parent export would NOT re-enqueue us — leaving the Linear issue
      #     under its old parent until a manual resync.
      raise ParentNotExportedError if parent_export_pending?

      if issue_link.nil?
        create_issue!(client, project_link, attrs, hash, parent_id)
      else
        update_issue!(client, issue_link, attrs, hash, parent_id)
      end
    end

    private

    # True when this creative's parent is itself part of the exported subtree
    # (it resolves the governing ProjectLink) but has not yet been exported to
    # Linear (no linear_issue_id). The parent MUST land first so this child can
    # be nested under it. The ProjectLink-root creative's own parent is outside
    # the subtree (resolves no link), so the root never defers.
    def parent_export_pending?
      parent = @creative.parent
      return false unless parent
      return false if parent.linear_issue_links.first&.linear_issue_id.present?

      # Parent is in the linked subtree only if it (or an ancestor) holds a
      # ProjectLink. If not, the parent is above the linked root — no wait.
      parent.self_and_ancestors.any? do |ancestor|
        CollavreLinear::ProjectLink.exists?(creative_id: ancestor.id)
      end
    end

    # Wrap a Collavre::Creative in the adapter expected by FieldMapper.
    # :title is derived from creative_snippet (plain-text, max 24 chars).
    def adapt(creative)
      CreativeAdapter.new(
        title:       creative.creative_snippet,
        description: creative.description,
        sequence:    creative.sequence,
        data:        creative.data
      )
    end

    # Walk self-and-ancestors (nearest first) to find a ProjectLink.
    # closure_tree's `self_and_ancestors` returns [self, parent, grandparent, …].
    def resolve_project_link
      @creative.self_and_ancestors.each do |ancestor|
        link = CollavreLinear::ProjectLink.find_by(creative_id: ancestor.id)
        return link if link
      end
      nil
    end

    # Find the parent Creative's linear_issue_id, if any.
    def parent_linear_issue_id
      self.class.parent_linear_issue_id_for(@creative)
    end

    # SHA-256 of the sorted, serialised mapped attrs plus the parent's linear
    # issue id (stable key order). Shared with CreativeExporter.content_hash_for
    # so inbound + outbound agree, including on reparents.
    def compute_content_hash(attrs, parent_id)
      self.class.hash_attrs(attrs, parent_id)
    end

    def create_issue!(client, project_link, attrs, hash, parent_id)
      response   = client.create_issue(
        team_id:    project_link.team_id,
        project_id: project_link.linear_project_id,
        parent_id:  parent_id,
        **attrs
      )

      linear_issue_id = response[:id]

      issue_link = CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    project_link,
        linear_issue_id: linear_issue_id,
        parent_issue_id: parent_id,
        content_hash:    hash,
        remote_updated_at: Time.current,
        local_version:   1,
        sync_state:      :synced
      )

      EchoGuard.record_outbound(issue_link, linear_issue_id)
      issue_link
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # Self-echo race: the inbound webhook for the issue we JUST created can land
      # in the window between create_issue and IssueLink.create! (app_actor_id is
      # nil, so EchoGuard can't drop it), creating a duplicate Creative that grabs
      # the IssueLink first. Adopt that link onto our original creative and remove
      # the duplicate so the issue isn't double-represented and our creative isn't
      # left unlinked. Any other validation error must still surface.
      raise if e.is_a?(ActiveRecord::RecordInvalid) && !duplicate_issue_link_error?(e)

      reconcile_self_echo!(linear_issue_id, project_link, hash, parent_id)
    end

    # True when the RecordInvalid is exactly the IssueLink linear_issue_id
    # uniqueness collision (the self-echo race), not some other invalid record.
    def duplicate_issue_link_error?(error)
      record = error.record
      record.is_a?(CollavreLinear::IssueLink) &&
        record.errors.of_kind?(:linear_issue_id, :taken)
    end

    def reconcile_self_echo!(linear_issue_id, project_link, hash, parent_id)
      existing = CollavreLinear::IssueLink.find_by(linear_issue_id: linear_issue_id)
      return existing unless existing

      duplicate = existing.creative
      CollavreLinear::IssueLink.transaction do
        existing.update!(
          creative:          @creative,
          project_link:      project_link,
          parent_issue_id:   parent_id,
          content_hash:      hash,
          remote_updated_at: Time.current,
          local_version:     1,
          sync_state:        :synced
        )

        # Remove the echo duplicate. The link was reassigned above, so this must
        # NOT archive the Linear issue we just created — skip_linear_sync guards
        # the destroy observer, and the creative now holds no IssueLink anyway.
        if duplicate && duplicate.id != @creative.id
          duplicate.skip_linear_sync = true
          duplicate.destroy!
        end
      end

      EchoGuard.record_outbound(existing, linear_issue_id)
      existing
    end

    def update_issue!(client, issue_link, attrs, hash, parent_id)
      issue_link.with_lock do
        # Conflict policy (see docs "Conflict handling"): a newer inbound Linear
        # change flipped this link to :conflict. Auto-sync HALTS until an explicit
        # resync resolves it — a stale queued job must never overwrite the remote
        # change we already chose not to clobber.
        return issue_link if issue_link.conflict?

        # Re-check under lock: a concurrent update with identical content must not
        # trigger a redundant API call.  The pre-lock check is gone intentionally
        # to eliminate the TOCTOU window between the dirty-check and the lock
        # acquisition.
        if issue_link.content_hash == hash
          # Content is already in sync with Linear.  If the observer marked the
          # link :dirty (e.g. for a metadata-only save that touched no mapped
          # field), reset it now so a subsequent inbound update does not
          # incorrectly trip conflict?.  Use update_column to avoid callbacks.
          if issue_link.dirty?
            issue_link.update_column(:sync_state, CollavreLinear::IssueLink.sync_states[:synced])
          end
          return issue_link
        end

        # Carry parentId on update so a reparent in Collavre moves the issue in
        # Linear too. Only send it when the parent is itself a linked Linear
        # issue (mirrors create_issue!); sending a nil/bogus parentId would error.
        update_fields = attrs
        update_fields = update_fields.merge(parent_id: parent_id) if parent_id

        response = client.update_issue(issue_link.linear_issue_id, **update_fields)

        issue_link.update!(
          content_hash:      hash,
          parent_issue_id:   parent_id,
          remote_updated_at: Time.current,
          local_version:     issue_link.local_version + 1,
          sync_state:        :synced
        )

        EchoGuard.record_outbound(issue_link, response[:id])
      end

      issue_link
    end
  end
end
