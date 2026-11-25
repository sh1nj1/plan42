# frozen_string_literal: true

module Collavre
  module Creatives
    class DraftLinkProgressReconciliation
      attr_reader :ids

      def initialize(mode, targets, records, writable_ids, user, anchor_id)
        @ids = Set.new
        return unless mode == :draft

        sources = authorized_sources(targets, records, writable_ids, user, anchor_id)
        @ids = PropagatedChangeAuthorization.new(changes: targets.keys, records: records, writable_source_ids: sources)
          .call.select { |_id, attributes| Array(attributes) == [ "progress" ] }.keys.to_set
      end

      def resolved?(change, creative)
        ids.include?(change.id) && !SnapshotComparison.conflict?(creative, change.before, ignore: [ "progress" ])
      end

      private

      def authorized_sources(targets, records, writable_ids, user, anchor_id)
        authorization = DraftLinkAuthorization.new(user: user)
        virtual_ids = targets.keys.select { |change| change.before.empty? }.map(&:creative_id).to_set
        targets.filter_map do |change, snapshot|
          next unless change.before.empty? && records[change.creative_id].nil? && snapshot["origin_id"]
          next unless authorization.creation_allowed?(snapshot, records, writable_ids: writable_ids,
                                                     virtual_ids: virtual_ids, anchor_id: anchor_id)

          change.creative_id
        end.to_set
      end
    end
  end
end
