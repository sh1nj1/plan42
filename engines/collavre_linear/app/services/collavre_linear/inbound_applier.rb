# frozen_string_literal: true

module CollavreLinear
  # Task 10 — applies a verified inbound Linear webhook payload to local Collavre
  # state (Creatives, IssueLinks, CommentLinks).
  #
  # `payload` is a PARSED HASH with string keys, exactly as InboundApplyJob hands
  # it over (never a JSON string). Shape (Linear webhook envelope):
  #
  #   {
  #     "action"      => "create" | "update" | "remove",
  #     "type"        => "Issue" | "Comment" | ...,
  #     "data"        => { ...entity fields... },
  #     "updatedFrom" => { ...changed fields (update only)... },
  #     "webhookTimestamp" => <ms epoch>
  #   }
  #
  # Loop guard: every Creative mutated here gets `skip_linear_sync = true` set
  # BEFORE save, so the CreativeSyncObserver's after_commit does NOT bounce the
  # change straight back out to Linear (echo prevention, Task 8).
  #
  # Sequence writes: FieldMapper only COMPUTES the sequence integer. We assign it
  # through the closure_tree-managed model (`creative.sequence = value; save!`),
  # never `update_column`/`update_all`, so the model's ordering callbacks run.
  # Core `Collavre::Creative` has no dedicated reorder helper (it relies on
  # `has_closure_tree order: :sequence` with a plain `sequence` column), so the
  # attribute-assign-then-save path is the correct model-level write.
  #
  # Conflict rule: if the local link is `dirty` (has un-synced local edits) AND
  # the remote payload is strictly NEWER than what we last saw
  # (`remote_updated_at`), we do NOT overwrite local data. We flip the link to
  # `conflict`, post a system comment noting the collision, and skip the field
  # apply. "Newer" = remote timestamp > link.remote_updated_at, where the remote
  # timestamp is taken from `data["updatedAt"]` (parsed) and falls back to
  # `webhookTimestamp` (ms epoch) when `updatedAt` is absent.
  class InboundApplier
    def initialize(payload)
      @payload = payload || {}
      @action  = @payload["action"]
      @type    = @payload["type"]
      @data    = @payload["data"] || {}
    end

    def apply!
      case @type
      when "Comment"
        apply_comment!
      else # "Issue" (default)
        apply_issue!
      end
    end

    private

    # -- Issue events ----------------------------------------------------------

    def apply_issue!
      case @action
      when "create" then create_issue!
      when "update" then update_issue!
      when "remove" then remove_issue!
      end
    end

    def create_issue!
      linear_issue_id = @data["id"]
      return if linear_issue_id.blank?
      # Idempotency: a create we already have is a no-op.
      return if IssueLink.find_by(linear_issue_id: linear_issue_id)

      parent_creative = resolve_create_parent
      return unless parent_creative

      attrs = FieldMapper.issue_to_creative_attrs(@data)

      # Wrap Creative + IssueLink in ONE transaction so a concurrent duplicate
      # `create` delivery that loses the unique linear_issue_id race also rolls
      # back the just-saved Creative — otherwise the loser leaves an orphan
      # Creative with no IssueLink.
      Collavre::Creative.transaction do
        creative = Collavre::Creative.new(
          description: description_for(attrs),
          user:        actor_user,
          parent:      parent_creative
        )
        creative.skip_linear_sync = true
        merge_linear_data!(creative, attrs[:data_linear])
        creative.sequence = attrs[:sequence]
        creative.save!

        IssueLink.create!(
          creative:          creative,
          project_link:      project_link,
          linear_issue_id:   linear_issue_id,
          parent_issue_id:   @data["parentId"],
          remote_updated_at: remote_updated_at,
          sync_state:        :synced
        )

        # Out-of-order delivery: children whose `create` arrived before this
        # parent were attached to the project root (resolve_create_parent's
        # fallback) but recorded parent_issue_id. Now that the parent Creative
        # exists, reparent them so the tree isn't permanently flattened.
        reparent_pending_children!(linear_issue_id, creative)
      end
    rescue ActiveRecord::RecordNotUnique
      # TOCTOU: a concurrent webhook already committed the IssueLink for this
      # linear_issue_id (DB unique index). The enclosing transaction rolled back
      # the Creative we started, so no orphan remains. Treat as already-applied.
      nil
    rescue ActiveRecord::RecordInvalid => e
      # Same race, but the duplicate was already visible to the model-level
      # uniqueness validation. Only swallow the linear_issue_id collision; any
      # other validation failure must still surface.
      raise unless duplicate_issue_link_error?(e)

      nil
    end

    # True when the RecordInvalid is exactly the IssueLink linear_issue_id
    # uniqueness collision (the duplicate-create race), not some other invalid.
    def duplicate_issue_link_error?(error)
      record = error.record
      record.is_a?(IssueLink) &&
        record.errors.of_kind?(:linear_issue_id, :taken)
    end

    def update_issue!
      link = IssueLink.find_by(linear_issue_id: @data["id"])
      return unless link

      link.with_lock do
        if conflict?(link)
          mark_conflict!(link)
          return
        end

        creative = link.creative
        attrs    = FieldMapper.issue_to_creative_attrs(@data)
        changed  = changed_keys

        creative.skip_linear_sync = true

        # Apply only fields that actually changed (per updatedFrom) when the hint
        # is present; otherwise apply the full mapped set.
        if changed.nil? || changed.include?("title") || changed.include?("description")
          creative.description = description_for(attrs)
        end
        if changed.nil? || changed.include?("priority")
          creative.sequence = attrs[:sequence]
        end
        merge_linear_data!(creative, attrs[:data_linear])

        # Reparent: when the payload's Linear parent differs from what the link
        # last recorded, move the Creative under the corresponding linked parent
        # and track the new parent_issue_id. Without this the tree stays under the
        # old parent AND the content hash below (which folds in the parent's
        # linear_issue_id) would record the OLD parent as synced, hiding the
        # divergence from later outbound syncs. Assigned before save! so the
        # skip_linear_sync guard covers the reparent (no echo back to Linear).
        new_parent_issue_id = apply_parent_change!(creative, link)

        creative.save!

        # Advance the outbound content hash to the newly-applied state. Without
        # this the link still holds the OLD outbound hash, so a later local edit
        # back to that old state would make CreativeExporter#update_issue! skip
        # the push, leaving Linear stale. Recompute with the exact same hashing
        # the exporter uses. reload picks up the persisted, closure_tree-managed
        # sequence so inbound + outbound hashes agree.
        link.update!(
          remote_updated_at: remote_updated_at || link.remote_updated_at,
          parent_issue_id:   new_parent_issue_id,
          content_hash:      CreativeExporter.content_hash_for(creative.reload),
          sync_state:        :synced
        )
      end
    end

    # Reparent the Creative when the inbound Linear parent differs from what the
    # link last recorded. Returns the parent_issue_id that should be persisted on
    # the link (the new one when moved, the unchanged one otherwise).
    #
    # Guard: only reparent to a parent that is itself a linked issue in this
    # install. An unknown/unlinked parentId is left untouched (we do not move the
    # Creative to a bogus node). Clearing parentId (moved to project root) moves
    # the Creative under the ProjectLink root Creative, mirroring create.
    def apply_parent_change!(creative, link)
      # Only act when the payload actually reports a parent change. When
      # updatedFrom is present but omits parentId, the parent did not change.
      changed = changed_keys
      return link.parent_issue_id if changed && !changed.include?("parentId")

      new_parent_issue_id = @data["parentId"].presence
      return link.parent_issue_id if new_parent_issue_id == link.parent_issue_id

      new_parent = resolve_reparent_target(new_parent_issue_id)
      # Unknown/unlinked parent: leave the tree and the link untouched.
      return link.parent_issue_id unless new_parent
      return link.parent_issue_id if new_parent.id == creative.parent_id

      creative.parent = new_parent
      new_parent_issue_id
    end

    # Resolve the Creative to reparent under for an inbound parent change.
    #   - a linked issue id -> that issue's Creative
    #   - a blank/absent parentId (moved to project root) -> the ProjectLink root
    #   - an unknown/unlinked issue id -> nil (caller leaves as-is)
    def resolve_reparent_target(parent_issue_id)
      if parent_issue_id.present?
        IssueLink.find_by(linear_issue_id: parent_issue_id)&.creative
      else
        project_link&.creative
      end
    end

    # Decision B6: NO destructive reparent of children. Mark an archive flag and
    # note it on the link; never destroy the Creative or move its children.
    def remove_issue!
      link = IssueLink.find_by(linear_issue_id: @data["id"])
      return unless link

      link.with_lock do
        creative = link.creative
        data = (creative.data || {}).deep_dup
        data["linear"] ||= {}
        data["linear"]["archived"] = true
        creative.skip_linear_sync = true
        creative.data = data
        creative.save!

        link.update!(sync_state: :synced)
      end
    end

    # -- Comment events --------------------------------------------------------

    def apply_comment!
      linear_comment_id = @data["id"]
      return if linear_comment_id.blank?

      # A Linear `remove` must delete the mirrored comment, never fall through to
      # the upsert path — otherwise it would overwrite/blank the local comment or
      # create an empty one. Handled before issue-link resolution since a removal
      # only needs the CommentLink mapping.
      return remove_comment!(linear_comment_id) if @action == "remove"

      issue_link = resolve_comment_issue_link
      return unless issue_link

      body = @data["body"].to_s
      comment_link = CommentLink.find_by(linear_comment_id: linear_comment_id)

      if comment_link
        comment = Collavre::Comment.find_by(id: comment_link.comment_id)
        comment&.update!(content: body)
      else
        creative = issue_link.creative
        comment = creative.comments.create!(
          content:       body,
          user:          comment_actor_user(issue_link),
          skip_dispatch: true
        )
        CommentLink.create!(
          comment_id:        comment.id,
          linear_comment_id: linear_comment_id,
          issue_link:        issue_link
        )
      end
    end

    # Delete the locally-mirrored comment when Linear removes it. No-op when the
    # comment was never linked, so a stray remove event can't create a blank
    # comment.
    def remove_comment!(linear_comment_id)
      comment_link = CommentLink.find_by(linear_comment_id: linear_comment_id)
      return unless comment_link

      Collavre::Comment.find_by(id: comment_link.comment_id)&.destroy
      comment_link.destroy
    end

    # -- Parent / link resolution ---------------------------------------------

    # Reparent any already-linked children that reference this newly-created
    # parent issue but were attached elsewhere (project root) because the
    # parent's create webhook hadn't arrived yet. Skips children already nested
    # correctly. skip_linear_sync so the reparent doesn't echo back out.
    def reparent_pending_children!(parent_linear_issue_id, parent_creative)
      IssueLink.where(parent_issue_id: parent_linear_issue_id).find_each do |child_link|
        child = child_link.creative
        next if child.nil? || child.parent_id == parent_creative.id

        child.skip_linear_sync = true
        child.update!(parent: parent_creative)
      end
    end

    # For create: nest under the parent issue's Creative if that parent is linked,
    # otherwise fall back to the ProjectLink's root Creative.
    def resolve_create_parent
      if (parent_issue_id = @data["parentId"]).present?
        parent_link = IssueLink.find_by(linear_issue_id: parent_issue_id)
        return parent_link.creative if parent_link
      end
      project_link&.creative
    end

    # Resolve the governing ProjectLink for this payload. Preference order:
    #   1. explicit projectId / project.id on the entity,
    #   2. the parent issue's ProjectLink (sub-issue create),
    #   3. the sole ProjectLink when the install has exactly one (common case:
    #      one linked project — avoids a fragile guess when Linear omits the id).
    def project_link
      return @project_link if defined?(@project_link)

      @project_link =
        if (pid = @data["projectId"] || @data.dig("project", "id")).present?
          ProjectLink.find_by(linear_project_id: pid)
        elsif (parent_issue_id = @data["parentId"]).present? &&
              (pl = IssueLink.find_by(linear_issue_id: parent_issue_id))
          pl.project_link
        elsif ProjectLink.count == 1
          ProjectLink.first
        end
    end

    def resolve_comment_issue_link
      issue_id = @data.dig("issue", "id") || @data["issueId"]
      return unless issue_id

      IssueLink.find_by(linear_issue_id: issue_id)
    end

    # -- Conflict detection ----------------------------------------------------

    def conflict?(link)
      return false unless link.dirty?

      remote = remote_updated_at
      return false unless remote

      # When remote_updated_at is nil there is no baseline to compare against —
      # we cannot determine that the remote is newer, so we allow the apply.
      local = link.remote_updated_at
      return false unless local

      remote > local
    end

    def mark_conflict!(link)
      link.update!(sync_state: :conflict)
      post_conflict_comment(link.creative)
    end

    def post_conflict_comment(creative)
      creative.comments.create!(
        content:       conflict_message,
        user:          actor_user,
        topic:         creative.main_topic(fallback_user: actor_user),
        skip_dispatch: true
      )
    rescue StandardError => e
      # A notification failure must never mask the (correct) skip-apply behavior.
      Rails.logger.error(
        "[CollavreLinear::InboundApplier] failed to post conflict comment: " \
        "#{e.class}: #{e.message}"
      )
    end

    def conflict_message
      I18n.t("collavre_linear.integration.conflict_notice")
    end

    # -- Field helpers ---------------------------------------------------------

    # Collavre::Creative has no title column — the canonical text lives in
    # `description` (title is derived from it via creative_snippet). Prefer the
    # mapped description; fall back to the issue title when description is blank.
    def description_for(attrs)
      desc = attrs[:description].presence
      title = attrs[:title].presence
      desc || title || ""
    end

    def merge_linear_data!(creative, data_linear)
      return if data_linear.blank?

      data = (creative.data || {}).deep_dup
      data["linear"] ||= {}
      data["linear"].merge!(data_linear.deep_stringify_keys)
      creative.data = data
    end

    # `updatedFrom` (update events) lists the fields that changed. Returns nil
    # when absent so callers apply the full mapped set.
    def changed_keys
      uf = @payload["updatedFrom"]
      return nil unless uf.is_a?(Hash)

      uf.keys
    end

    def remote_updated_at
      if (ts = @data["updatedAt"]).present?
        return Time.zone.parse(ts.to_s) rescue nil
      end
      if (wt = @payload["webhookTimestamp"]).present?
        # webhookTimestamp is milliseconds since epoch.
        return Time.zone.at(wt.to_i / 1000.0)
      end
      nil
    end

    def actor_user
      @actor_user ||= project_link&.account&.user
    end

    # Owner for an inbound COMMENT. Comment payloads carry no projectId/parentId,
    # so the memoized `project_link` falls back to the sole ProjectLink and is
    # nil in multi-project installs — which would drop author attribution. The
    # governing project is unambiguous here: it's the one the resolved issue_link
    # belongs to. Prefer that; fall back to actor_user only when issue_link is
    # absent (e.g. the conflict-comment path has no issue_link in scope).
    def comment_actor_user(issue_link)
      issue_link&.project_link&.account&.user || actor_user
    end
  end
end
