module Collavre
  module Creatives
    # Reserve a first saved child for each origin; share extra rows fairly within
    # each level. Unreadable siblings cannot consume another origin's first probe.
    # Both counters span the entire restoration: at most 2 * limit rows are read.
    class WorkspaceExpansionCandidates
      def initialize(limit:)
        @parents_remaining = limit
        @extra_remaining = limit
      end

      def rows(candidates, origin_ids)
        parents = origin_ids.first(@parents_remaining)
        @parents_remaining -= parents.size
        parents.each_with_index.flat_map do |origin_id, position|
          quota = 1 + @extra_remaining / (parents.size - position)
          rows = candidates.where(parent_id: origin_id).limit(quota).pluck(:id, :parent_id)
          @extra_remaining -= [ rows.size - 1, 0 ].max
          rows
        end
      end
    end
  end
end
