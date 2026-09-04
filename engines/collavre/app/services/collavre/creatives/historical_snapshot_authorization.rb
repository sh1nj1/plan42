# frozen_string_literal: true

module Collavre
  module Creatives
    class HistoricalSnapshotAuthorization
      def self.initial_attributes(creative, before, position)
        { before: before, position: position, conflict: metadata_for(creative) }
      end

      def self.metadata_for(creative)
        { "before_owner_id" => creative.effective_origin(Set.new).user_id }
      end

      def initialize(user:)
        @user_id = user&.id
      end

      def before_visible?(changes)
        moved_changes = changes.select do |change|
          change.before.present? && change.after.present? &&
            change.before["parent_id"] != change.after["parent_id"]
        end
        moved_changes.empty? || moved_changes.all? do |change|
          change.conflict["before_owner_id"] == @user_id
        end
      end
    end
  end
end
