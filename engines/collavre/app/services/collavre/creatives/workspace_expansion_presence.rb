module Collavre
  module Creatives
    # Unsaved children establish expandability without consuming the saved-ID
    # traversal budget. SQL rows and permission checks are bounded per branch.
    class WorkspaceExpansionPresence
      def initialize(user:, limit:)
        @filter = PermissionFilter.new(user: user)
        @limit = limit
      end

      def visible_child?(creative, excluding:)
        candidates = Creative.active.where(parent_id: creative.effective_origin.id).where.not(id: excluding.to_a)
        remaining = @limit
        offset = 0
        while remaining.positive?
          batch_size = offset.zero? ? 1 : 100
          ids = candidates.reorder(:sequence, :id).offset(offset).limit([ remaining, batch_size ].min).pluck(:id)
          return false if ids.empty?

          remaining -= ids.size
          return true if @filter.readable_ids(ids).any?

          offset += ids.size
        end
        false
      end
    end
  end
end
