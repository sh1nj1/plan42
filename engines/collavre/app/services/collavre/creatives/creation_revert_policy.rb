# frozen_string_literal: true

module Collavre
  module Creatives
    class CreationRevertPolicy
      def initialize(changes:)
        @created_creative_ids = changes.select { |change| change.before.empty? }.map(&:creative_id).to_set
      end

      def conflict?(creative)
        family_for(creative).where(archived_at: nil).where.not(id: @created_creative_ids).exists?
      end

      def resolved?(creative, snapshot)
        return already_reverted?(creative) if snapshot.empty?

        History.snapshot(creative) == snapshot
      end

      def archive!(creative)
        creative.origin_id? ? creative.archive_placement_subtree! : creative.archive!
      end

      private

      def already_reverted?(creative)
        family_for(creative).where(archived_at: nil).none?
      end

      def family_for(creative)
        creative.origin_id? ? creative.self_and_descendants : creative.archive_family
      end
    end
  end
end
