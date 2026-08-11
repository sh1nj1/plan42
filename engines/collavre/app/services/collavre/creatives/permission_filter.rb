module Collavre
module Creatives
  # Batch "which of these creative ids can the user read?" using the O(1)
  # CreativeSharesCache table. Extracted from FilterPipeline so the picker's
  # has_children presence check can apply the exact same permission posture as
  # the browse endpoint (children_with_permission) without re-deriving it.
  #
  # A user-specific cache entry is authoritative over a public share: it grants
  # only when its own rank meets the requested threshold and otherwise suppresses
  # the public share (so a no_access — or any below-threshold user entry — wins
  # over a more permissive public share). Owned creatives are always readable.
  class PermissionFilter
    # An owner always resolves to admin, the top rank, so it satisfies any
    # min_permission threshold. This is the canonical owner rank the read-path
    # callers (TreeBuilder, SlideViewable) inherit via #ranks_for / #readable_ids.
    OWNER_RANK = CreativeShare.permissions[:admin]

    def initialize(user:)
      @user = user
    end

    # Returns the candidate user ids that may access a creative at the requested
    # permission level. This is the inverse of #readable_ids: it resolves one
    # creative for many users without issuing a permission-cache query per user.
    # User-specific cache entries remain authoritative over a public entry.
    def self.permitted_user_ids(creative, user_ids, min_permission: :read)
      user_ids = user_ids.to_a.filter_map { |id| Integer(id, exception: false) }.uniq
      return [] if creative.blank? || user_ids.empty?

      effective = EffectiveCreativeResolution.effective_creative(creative)
      min_rank = CreativeShare.permissions.fetch(min_permission.to_s)
      permissions_by_user_id = CreativeSharesCache
        .where(creative_id: effective.id, user_id: user_ids + [ nil ])
        .pluck(:user_id, :permission)
        .to_h
      public_permission = permissions_by_user_id.delete(nil)

      user_ids.select do |user_id|
        if user_id == effective.user_id
          true
        elsif permissions_by_user_id.key?(user_id)
          CreativeShare.permissions.fetch(permissions_by_user_id[user_id]) >= min_rank
        else
          public_permission && CreativeShare.permissions.fetch(public_permission) >= min_rank
        end
      end
    end

    # Returns the subset of `ids` the user may access at `min_permission` or
    # higher, as an Array. `min_permission:` defaults to `:read`, so the no-arg
    # form is unchanged; pass `:write` (etc.) to share the one batch filter with
    # write-posture sites instead of re-deriving the rank comparison.
    #
    # Each id is resolved to its effective (origin) creative via the SAME
    # logic PermissionChecker uses, so a linked creative yields identical
    # permission whether checked one-by-one or filtered in a batch.
    def readable_ids(ids, min_permission: :read)
      # Normalize to Integer so the final select (and owned-shell lookup) compare
      # against pluck-derived integer ids rather than string inputs; keeps the
      # canonical batch filter robust to param-sourced ids. Non-numeric ids drop.
      ids = ids.to_a.filter_map { |id| Integer(id, exception: false) }.uniq
      return [] if ids.empty?

      min_rank = rank_for(min_permission)
      effective_by_id = EffectiveCreativeResolution.effective_creative_ids(ids)
      readable_effective = readable_effective_ids(effective_by_id.values.uniq, min_rank)

      # A linked creative borrows its ORIGIN's permission, but the shell row
      # itself represents a specific PLACEMENT of that link inside a tree.
      # Returning a shell solely because its origin is readable would leak other
      # users' private shell placements into search/filter results — a batch can
      # be fed foreign shells (e.g. FilterPipeline#resolve_ancestors pulls every
      # Creative.where(origin_id: ...) regardless of owner). So a shell is gated
      # on the viewer being able to SEE its placement at the requested rank, in
      # ADDITION to origin readability: either the viewer owns the shell, or the
      # shell sits in a subtree shared with the viewer AT >= min_permission (a
      # propagated CreativeSharesCache entry on the shell row itself — e.g. a
      # public help doc's linked child). The placement is checked at min_rank
      # (not always :read) because higher-privilege callers share this batch —
      # children_with_permission(user, :admin), used by DestroyService's
      # recursive delete, must not reach a shell the viewer only has read on. A
      # shell in a foreign PRIVATE tree (no viewer entry) stays hidden. Non-shell
      # ids keep origin-readability-only behaviour.
      visible_shells = visible_shell_ids(effective_by_id, min_rank)

      ids.select do |id|
        next false unless readable_effective.include?(effective_by_id[id])

        effective_by_id[id] == id || visible_shells.include?(id)
      end
    end

    # Returns { input_id => effective_permission_rank } for the ids the user has
    # ANY relationship to, mirroring single-item PermissionChecker: owner wins
    # (admin rank), else the user's own cache entry (INCLUDING a no_access deny,
    # which is rank 0 and beats a public share), else the public entry. Ids with
    # no owner/entry/public share are ABSENT from the hash (distinct from rank 0).
    #
    # The rank is the raw CreativeShare.permissions integer, so callers compare
    # `rank >= rank_for(:write)` themselves. Unlike readable_ids this does NOT
    # apply the shell-ownership anti-leak gate — it is for tree_builder /
    # slide_viewable which rank creatives already inside the viewer's own tree,
    # exactly as PermissionChecker#allowed? would resolve them one by one.
    def ranks_for(ids)
      ids = ids.to_a.filter_map { |id| Integer(id, exception: false) }.uniq
      return {} if ids.empty?

      effective_by_id = EffectiveCreativeResolution.effective_creative_ids(ids)
      effective_ids = effective_by_id.values.uniq

      owner_by_effective = Creative.where(id: effective_ids).pluck(:id, :user_id).to_h

      user_entries = if user
        CreativeSharesCache.where(creative_id: effective_ids, user_id: user.id)
          .pluck(:creative_id, :permission).to_h
      else
        {}
      end

      needs_public = effective_ids - user_entries.keys
      public_entries = if needs_public.any?
        CreativeSharesCache.where(creative_id: needs_public, user_id: nil)
          .pluck(:creative_id, :permission).to_h
      else
        {}
      end

      ranks = {}
      ids.each do |id|
        effective = effective_by_id[id]
        if user && owner_by_effective[effective] == user.id
          ranks[id] = OWNER_RANK
        else
          permission = user_entries[effective] || public_entries[effective]
          ranks[id] = CreativeShare.permissions[permission] if permission
        end
      end
      ranks
    end

    private

    attr_reader :user

    def rank_for(permission)
      CreativeShare.permissions.fetch(permission.to_s)
    end

    # The subset of shell ids (effective != self) whose PLACEMENT the viewer can
    # see AT `min_rank`: shells the viewer owns, plus shells sitting in a subtree
    # shared with the viewer at >= min_rank. A shell inside a shared/public tree
    # inherits a propagated CreativeSharesCache entry keyed on its own id
    # (PermissionCacheBuilder#propagate_share walks [creative] + descendants,
    # which includes placed shells), so readability of the shell id itself
    # captures exactly "the viewer may act on this link here at this rank". The
    # placement is checked at the caller's min_rank rather than always :read
    # because higher-privilege callers share this batch — e.g.
    # children_with_permission(user, :admin) drives DestroyService's recursive
    # delete, which must not reach a placement the viewer only has read on. A
    # shell in a foreign private tree has no entry and is excluded, preserving
    # the anti-leak guarantee against FilterPipeline#resolve_ancestors' owner-
    # agnostic pull.
    def visible_shell_ids(effective_by_id, min_rank = rank_for(:read))
      shell_ids = effective_by_id.filter_map { |id, effective| id if effective != id }
      return Set.new if shell_ids.empty?

      readable_effective_ids(shell_ids, min_rank)
    end

    # Returns the subset of already-origin-resolved ids the user may access at
    # `min_rank` or higher, as a Set. A user-specific entry is authoritative:
    # it grants only when its own rank meets the threshold and otherwise
    # suppresses the public share entirely (so a user no_access — or any
    # below-threshold user entry — wins over a more permissive public share).
    # Owned creatives are always accessible (owner has admin).
    def readable_effective_ids(ids, min_rank = rank_for(:read))
      return Set.new if ids.empty?

      accessible_ids = Set.new

      if user
        user_has_entry = Set.new
        CreativeSharesCache.where(creative_id: ids, user_id: user.id)
          .pluck(:creative_id, :permission).each do |cid, perm|
            user_has_entry << cid
            accessible_ids << cid if CreativeShare.permissions[perm] >= min_rank
          end

        public_ids = CreativeSharesCache.where(creative_id: ids, user_id: nil)
          .where("permission >= ?", min_rank).pluck(:creative_id)
        accessible_ids.merge(public_ids.reject { |cid| user_has_entry.include?(cid) })

        owned_ids = Creative.where(id: ids, user_id: user.id).pluck(:id)
        accessible_ids.merge(owned_ids)
      else
        accessible_ids = CreativeSharesCache.where(creative_id: ids, user_id: nil)
          .where("permission >= ?", min_rank).pluck(:creative_id).to_set
      end

      accessible_ids
    end
  end
end
end
