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
  # Conflict rule: when the local link is `dirty` (has un-synced local edits) the
  # inbound payload is dispositioned against our last-seen remote timestamp
  # (`remote_updated_at`):
  #   * remote strictly NEWER than baseline => genuine concurrent remote edit =>
  #     flip to `conflict`, post a Main-topic comment, skip the field apply.
  #   * remote present but NOT newer (<=) => a stale echo. A genuinely new remote
  #     edit always carries updatedAt > baseline, so a not-newer payload on a
  #     dirty link can only be our own outbound update webhooking back (or a
  #     replayed delivery). Applying it would clobber the newer pending local
  #     edit, so we no-op. (Especially reachable today: issue echo dropping is
  #     disabled while `app_actor_id` is nil.)
  #   * remote or baseline nil => no basis to compare => apply.
  # "Newer" = remote timestamp > link.remote_updated_at, where the remote
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
      when "Issue"
        apply_issue!
      end
      # Other types (e.g. Project — the webhook subscribes to it) are ignored:
      # routing them through apply_issue! would use the project UUID as a
      # linear_issue_id and create a blank Creative in a one-link install.
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
      # Out-of-order delivery: an `update` can be processed before the issue's
      # `create` webhook has committed its IssueLink (separate InboundApplyJobs,
      # multiple workers). Dropping it loses the edit permanently — the later
      # create only carries the original creation-time payload. The update `data`
      # is the full current entity, so upsert it as a create: the real create is
      # then idempotent, and a projectless/foreign issue still no-ops via
      # resolve_create_parent's proven-membership guard.
      return create_issue! unless link

      # Lock order MUST match the outbound path: OutboundSyncJob locks the
      # Creative row, then CreativeExporter#update_issue! locks the IssueLink.
      # Taking them in the opposite order (link then creative) lets a concurrent
      # inbound apply and outbound sync for the same creative deadlock on
      # PostgreSQL, and this job has no deadlock retry. Lock Creative, then link.
      creative = link.creative
      creative.with_lock do
        link.lock!

        # Already conflicted: halt until a human resolves (mirrors the outbound
        # exporter's `return if issue_link.conflict?`). conflict?(link) below only
        # trips for :dirty links, so without this a later remote update would
        # overwrite the local edits that caused the conflict and silently flip the
        # link back to :synced.
        return if link.conflict?

        case inbound_disposition(link)
        when :conflict
          mark_conflict!(link)
          return
        when :stale
          # Stale echo of an already-seen (or our own) remote state; applying it
          # would overwrite the newer pending local edit. Leave the link dirty so
          # the pending outbound push still carries the local edit to Linear.
          return
        end

        # Cross-project move: the payload places the issue in a DIFFERENT project
        # than the link records. It cannot be auto-applied — the Creative lives
        # under the old ProjectLink root, and re-homing it (together with its
        # linked sub-issues, which move with it in Linear) under the new root is
        # ambiguous. Applying + marking :synced would silently freeze the wrong
        # mapping (link.project_link stays the old project), so future outbound
        # syncs push against the wrong account. Surface it for a human instead.
        # (parentId-only moves within the same project are handled by
        # apply_parent_change!.) Fires only when the payload explicitly names a
        # project that differs — a same-project update carries the unchanged id.
        payload_project_id = @data["projectId"] || @data.dig("project", "id")
        if payload_project_id.present? &&
           payload_project_id != link.project_link.linear_project_id
          mark_conflict!(link)
          return
        end

        attrs    = FieldMapper.issue_to_creative_attrs(@data)
        changed  = changed_keys

        creative.skip_linear_sync = true

        # Apply only fields that actually changed (per updatedFrom) when the hint
        # is present; otherwise apply the full mapped set. The creative value
        # tracks the issue TITLE only — a description-only Linear edit must not
        # touch it (the description is ignored).
        if changed.nil? || changed.include?("title")
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
    # Guard: only move the Creative under a parent that is itself a linked issue.
    # For a not-yet-linked parent (its create webhook hasn't arrived) we still
    # record the new parent_issue_id so reparent_pending_children! can move the
    # Creative once the parent is created — we just don't move it to a bogus node
    # now. Clearing parentId (moved to project root) moves the Creative under the
    # ProjectLink root Creative, mirroring create.
    def apply_parent_change!(creative, link)
      # Only act when the payload actually reports a parent change. When
      # updatedFrom is present but omits parentId, the parent did not change.
      changed = changed_keys
      return link.parent_issue_id if changed && !changed.include?("parentId")

      new_parent_issue_id = @data["parentId"].presence
      return link.parent_issue_id if new_parent_issue_id == link.parent_issue_id

      new_parent = resolve_reparent_target(new_parent_issue_id)
      unless new_parent
        # The move targets a real Linear parent whose `create` webhook hasn't
        # been applied yet (out-of-order delivery). Record the NEW parent_issue_id
        # WITHOUT moving the tree: reparent_pending_children! keys on
        # parent_issue_id, so once the parent Creative is created it finds and
        # moves this child. Returning the OLD id would strand it under the old
        # parent forever (the create repair could never match it). A cleared
        # parentId (moved to project root) always resolves, so this only covers a
        # still-unknown, non-blank parent.
        return new_parent_issue_id if new_parent_issue_id.present?

        return link.parent_issue_id
      end
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

      # Same lock order as update_issue! / the outbound path: Creative then link.
      creative = link.creative
      creative.with_lock do
        link.lock!
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
      # The sequential linear_inbound queue applies webhooks in receipt order, so
      # a comment normally lands after its issue's create. If the issue is still
      # unlinked here, either Linear delivered the comment ahead of the create at
      # the network level (a rare residual the in-order queue can't fully close)
      # or the comment belongs to an unlinked issue — in both cases we have no
      # issue to attach to, so drop rather than guess.
      return unless issue_link

      body = @data["body"].to_s
      comment_link = CommentLink.find_by(linear_comment_id: linear_comment_id)

      if comment_link
        # Serialize against OutboundCommentUpdateJob, which holds this CommentLink's
        # lock across its Linear round-trip and only advances remote_updated_at
        # afterwards. Reading the baseline without the lock can observe the pre-update
        # value mid-flight, so the echo of our own outbound edit (a strictly-newer
        # updatedAt) is misclassified as a genuine Linear edit and clobbers the local
        # body with the outbound (author-prefixed) form. Lock + reload so the baseline
        # we compare against is the committed one, mirroring the issue apply path.
        comment_link.with_lock do
          comment = Collavre::Comment.find_by(id: comment_link.comment_id)
          # Apply genuine Linear-side edits; skip our own echoes. We compare the
          # webhook's updatedAt against the version we last synced (stored on the
          # link) rather than the mutable local body: a user may edit A->B locally
          # before Linear echoes the older A, and a body comparison would then treat
          # that stale echo as a real edit and clobber B. A strictly-newer remote
          # timestamp is the only thing that means a real Linear-side change.
          if comment && genuine_comment_edit?(comment_link)
            # skip_linear_sync so this Linear-originated edit does not echo back out
            # as an outbound update (which would re-wrap the author-name prefix).
            comment.skip_linear_sync = true
            comment.update!(content: body)
            comment_link.update!(remote_updated_at: remote_updated_at) if remote_updated_at
          end
        end
      else
        create_mirrored_comment!(issue_link, linear_comment_id, body)
      end
    end

    # True when this comment webhook is a real Linear-side edit rather than our
    # own (possibly stale) echo. "Real" = a remote updatedAt strictly newer than
    # the version we last synced. A missing baseline or remote timestamp falls
    # through to applying, mirroring how issue conflict detection treats an absent
    # baseline (we cannot prove staleness, so we do not silently drop the edit).
    def genuine_comment_edit?(comment_link)
      remote   = remote_updated_at
      baseline = comment_link.remote_updated_at
      return true unless remote && baseline

      remote > baseline
    end

    # Create the mirrored Collavre comment AND its CommentLink atomically. A
    # concurrent duplicate delivery can pass the CommentLink.find_by check above
    # and reach here twice; the loser hits the unique linear_comment_id index.
    # Wrapping both in one transaction rolls back the just-created Comment on that
    # collision, so no orphan (unlinked) duplicate comment is left behind.
    def create_mirrored_comment!(issue_link, linear_comment_id, body)
      author = user_matching_actor_email
      # A Linear author with no matching Collavre user becomes a SYSTEM comment
      # (user: nil), with the author's name prefixed into the body exactly as the
      # outbound Collavre->Linear direction does. A matched author is attributed
      # directly and needs no prefix.
      content = author ? body : CommentFormatter.prefixed_body(@payload.dig("actor", "name"), body)
      Collavre::Comment.transaction do
        comment = issue_link.creative.comments.new(
          content:       content,
          user:          author,
          skip_dispatch: true
        )
        # Suppress the outbound echo: this comment came FROM Linear, so the
        # CommentSyncObserver must not post it straight back as a new comment.
        comment.skip_linear_sync = true
        comment.save!
        CommentLink.create!(
          comment_id:        comment.id,
          linear_comment_id: linear_comment_id,
          issue_link:        issue_link,
          remote_updated_at: remote_updated_at
        )
      end
    rescue ActiveRecord::RecordNotUnique
      # DB unique index caught the duplicate; the transaction rolled back the
      # Comment. Already-applied — treat as a no-op.
      nil
    rescue ActiveRecord::RecordInvalid => e
      # Model-level uniqueness saw the duplicate first. Only swallow the
      # linear_comment_id collision; any other validation failure must surface.
      raise unless duplicate_comment_link_error?(e)

      nil
    end

    # True when the RecordInvalid is exactly the CommentLink linear_comment_id
    # uniqueness collision (the duplicate-delivery race), not another invalid.
    def duplicate_comment_link_error?(error)
      record = error.record
      record.is_a?(CommentLink) &&
        record.errors.of_kind?(:linear_comment_id, :taken)
    end

    # Delete the locally-mirrored comment when Linear removes it. No-op when the
    # comment was never linked, so a stray remove event can't create a blank
    # comment.
    def remove_comment!(linear_comment_id)
      comment_link = CommentLink.find_by(linear_comment_id: linear_comment_id)
      return unless comment_link

      comment = Collavre::Comment.find_by(id: comment_link.comment_id)
      if comment
        # skip_linear_sync so this Linear-originated removal does not echo back out
        # as an outbound delete of the comment Linear already deleted.
        comment.skip_linear_sync = true
        comment.destroy
      end
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

    # Resolve the governing ProjectLink for this payload. Membership must be
    # PROVEN — Linear webhooks are team-scoped, so a projectless issue (backlog,
    # or a different project in the same team) must not be adopted into a linked
    # project's subtree. Preference order:
    #   1. explicit projectId / project.id on the entity,
    #   2. the parent issue's ProjectLink (sub-issue whose parent is linked).
    # There is deliberately NO sole-ProjectLink fallback: a payload that names
    # neither a project nor a linked parent cannot prove it belongs to any linked
    # project, so it resolves to nil and the caller no-ops the import.
    def project_link
      return @project_link if defined?(@project_link)

      @project_link =
        if (pid = @data["projectId"] || @data.dig("project", "id")).present?
          ProjectLink.find_by(linear_project_id: pid)
        elsif (parent_issue_id = @data["parentId"]).present? &&
              (pl = IssueLink.find_by(linear_issue_id: parent_issue_id))
          pl.project_link
        end
    end

    def resolve_comment_issue_link
      issue_id = @data.dig("issue", "id") || @data["issueId"]
      return unless issue_id

      IssueLink.find_by(linear_issue_id: issue_id)
    end

    # -- Conflict detection ----------------------------------------------------

    # Classify how an inbound update should be treated relative to local state:
    #   :apply    — safe to apply (clean link, or dirty with no baseline to
    #               compare against).
    #   :conflict — dirty link AND remote strictly newer than baseline (genuine
    #               concurrent remote edit; human resolves).
    #   :stale    — dirty link AND remote present but NOT newer than baseline. A
    #               genuinely new remote edit always has updatedAt > baseline, so
    #               this can only be a stale/own echo; no-op rather than clobber
    #               the pending local edit.
    def inbound_disposition(link)
      return :apply unless link.dirty?

      remote   = remote_updated_at
      baseline = link.remote_updated_at
      # No basis to compare (fresh dirty link or missing remote stamp) — apply.
      return :apply unless remote && baseline

      remote > baseline ? :conflict : :stale
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
    # `description` (title is derived from it via creative_snippet). The Linear
    # issue TITLE is that canonical value; the Linear issue description is
    # intentionally ignored for now (product decision).
    def description_for(attrs)
      attrs[:title].presence || ""
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

    # Author for an inbound Linear COMMENT. A human writing in Linear should show
    # up as themselves in Collavre when their `actor.email` matches a Collavre
    # user. When it does not (Linear-only author, or no email), the caller stores
    # a system comment (nil user) with a "[name]:" prefix instead — never the
    # shared connecting account. Our own outbound comments never reach here: the
    # controller drops app-actor events via EchoGuard before enqueuing.
    def user_matching_actor_email
      email = @payload.dig("actor", "email")
      return nil if email.blank?

      # User#email is normalized to strip.downcase, so match the same way for a
      # case- and whitespace-insensitive lookup.
      Collavre.user_class.find_by(email: email.strip.downcase)
    end
  end
end
