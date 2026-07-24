module Collavre
module Creatives
  # Single source of truth for "which creative's cache/ownership actually
  # governs permission for this creative?".
  #
  # A linked creative (origin_id present) borrows its origin's permission: it
  # has no cache entries of its own and its ownership is the origin's ownership.
  # PermissionChecker (single-item) and PermissionFilter (batch) MUST resolve
  # the effective creative through this module so a single check and a batch
  # filter can never diverge for the same user + linked creative.
  module EffectiveCreativeResolution
    module_function

    # For a single loaded creative: returns the creative whose cache/ownership
    # governs permission. Non-linked creatives resolve to themselves.
    def effective_creative(creative)
      creative.origin_id.nil? ? creative : creative.origin
    end

    # For a batch of creative ids: returns { original_id => effective_id }.
    # Linked creatives map to their origin_id; every other id (including ids
    # not found in the table) maps to itself. This mirrors
    # +effective_creative+ so the batch reader resolves origin identically.
    def effective_creative_ids(ids)
      # Coerce to Integer: origin_by_id is keyed by integer ids from pluck, so a
      # string id (e.g. sourced from request params) would miss origin lookup
      # and later miss the integer-keyed readable Set. Non-numeric ids can't
      # identify a Creative, so drop them.
      ids = ids.to_a.filter_map { |id| Integer(id, exception: false) }.uniq
      return {} if ids.empty?

      origin_by_id = Creative.where(id: ids).pluck(:id, :origin_id).to_h
      ids.index_with { |id| origin_by_id[id] || id }
    end
  end
end
end
