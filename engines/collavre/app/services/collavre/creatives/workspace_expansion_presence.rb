module Collavre
  module Creatives
    # Unsaved children establish expandability without consuming the saved-ID
    # traversal budget. Reserve one probe per candidate so earlier hidden branches
    # cannot starve later candidates; deeper scans share one restoration budget.
    # At most limit candidates and 2 * limit child rows are inspected per render.
    class WorkspaceExpansionPresence
      def initialize(user:, limit:)
        @filter = PermissionFilter.new(user: user)
        @limit = limit
        @probes_remaining = limit
        @remaining = limit
      end

      def visible_child?(creative, excluding:)
        return false unless @probes_remaining.positive?

        @probes_remaining -= 1
        candidates = Creative.active.where(parent_id: creative.effective_origin.id).where.not(id: excluding.to_a)
        remaining = @limit
        offset = 0
        while remaining.positive?
          batch_size = offset.zero? ? 1 : [ 100, @remaining ].min
          break if batch_size.zero?
          ids = candidates.reorder(:sequence, :id).offset(offset).limit([ remaining, batch_size ].min).pluck(:id)
          return false if ids.empty?

          @remaining -= ids.size unless offset.zero?
          remaining -= ids.size
          return true if @filter.readable_ids(ids).any?

          offset += ids.size
        end
        false
      end
    end
  end
end
