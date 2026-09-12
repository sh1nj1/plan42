# frozen_string_literal: true

module Collavre
  module Creatives
    # Loads linked creative origins once per depth without changing root order.
    class OriginChainPreloader
      def self.preload(creatives)
        indexed = creatives.index_by(&:id)
        pending = creatives
        until pending.empty?
          origin_ids = pending.filter_map(&:origin_id).uniq - indexed.keys
          pending = Creative.where(id: origin_ids).to_a
          indexed.merge!(pending.index_by(&:id))
        end

        # Reuse the same records at every depth, including converging paths and cycles.
        indexed.each_value do |creative|
          creative.association(:origin).target = indexed[creative.origin_id] if creative.origin_id
        end
      end
    end
  end
end
