module Collavre
module Creatives
  # Batch "which of these creative ids can the user read?" using the O(1)
  # CreativeSharesCache table. Extracted from FilterPipeline so the picker's
  # has_children presence check can apply the exact same permission posture as
  # the browse endpoint (children_with_permission) without re-deriving it.
  #
  # no_access wins over a public share, so user-level denials are subtracted
  # from the public set. Owned creatives are always readable.
  class PermissionFilter
    def initialize(user:)
      @user = user
    end

    # Returns the subset of `ids` the user may read, as an Array.
    #
    # Each id is resolved to its effective (origin) creative via the SAME
    # logic PermissionChecker uses, so a linked creative yields identical
    # permission whether checked one-by-one or filtered in a batch.
    def readable_ids(ids)
      ids = ids.to_a
      return [] if ids.empty?

      effective_by_id = EffectiveCreativeResolution.effective_creative_ids(ids)
      readable_effective = readable_effective_ids(effective_by_id.values.uniq)

      # A linked creative borrows its ORIGIN's permission, but the shell row
      # itself is private to the user who created it (Linkable creates exactly
      # one shell per user+origin). Returning a shell solely because its origin
      # is readable would leak other users' shell placements into search/filter
      # results — a batch can be fed foreign shells (e.g. FilterPipeline#resolve_ancestors
      # pulls every Creative.where(origin_id: ...) regardless of owner). So a
      # shell is gated on ownership in ADDITION to origin readability; non-shell
      # ids keep origin-readability-only behaviour.
      owned_shells = owned_shell_ids(effective_by_id)

      ids.select do |id|
        next false unless readable_effective.include?(effective_by_id[id])

        effective_by_id[id] == id || owned_shells.include?(id)
      end
    end

    private

    attr_reader :user

    # The subset of shell ids (effective != self) that the viewer owns. Shells
    # have no cache/share rows of their own, so ownership of the shell row is
    # the only thing that scopes a shell to a viewer.
    def owned_shell_ids(effective_by_id)
      return Set.new unless user

      shell_ids = effective_by_id.filter_map { |id, effective| id if effective != id }
      return Set.new if shell_ids.empty?

      Creative.where(id: shell_ids, user_id: user.id).pluck(:id).to_set
    end

    # Returns the subset of already-origin-resolved ids the user may read,
    # as a Set. no_access wins over a public share; owned creatives are
    # always readable.
    def readable_effective_ids(ids)
      return Set.new if ids.empty?

      accessible_ids = Set.new

      if user
        user_accessible = []
        user_denied = Set.new
        CreativeSharesCache.where(creative_id: ids, user_id: user.id)
          .pluck(:creative_id, :permission).each do |cid, perm|
            perm == "no_access" ? user_denied << cid : user_accessible << cid
          end
        accessible_ids.merge(user_accessible)

        public_ids = CreativeSharesCache.where(creative_id: ids, user_id: nil)
          .where.not(permission: :no_access).pluck(:creative_id)
        accessible_ids.merge(public_ids - user_denied.to_a)

        owned_ids = Creative.where(id: ids, user_id: user.id).pluck(:id)
        accessible_ids.merge(owned_ids)
      else
        accessible_ids = CreativeSharesCache.where(creative_id: ids, user_id: nil)
          .where.not(permission: :no_access).pluck(:creative_id).to_set
      end

      accessible_ids
    end
  end
end
end
