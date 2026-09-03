# frozen_string_literal: true

module Collavre
  class Creative < ApplicationRecord
    module HistoryTrackable
      extend ActiveSupport::Concern

      included do
        around_save :record_change_history
        before_destroy :record_destroy_history

        has_many :creative_changes, class_name: "Collavre::CreativeChange", dependent: nil
      end

      def complete_self_and_descendants!
        targets = self_and_descendants.where(origin_id: nil)
        Creatives::History.record_bulk(targets, operation: "update") do
          targets.update_all(progress: 1.0, updated_at: Time.current)
        end
      end

      private

      def record_change_history(&block)
        Creatives::History.capture(self, &block)
      end

      def record_destroy_history
        Creatives::History.record(
          self,
          operation: "destroy",
          before: Creatives::History.snapshot(self),
          after: {}
        )
      end

      def archive_family_ids
        origin = effective_origin(Set.new)
        family = [ self, origin, *linked_creatives, *origin.linked_creatives ].uniq
        family.flat_map { |creative| creative.self_and_descendants.pluck(:id) }.uniq
      end
    end
  end
end
