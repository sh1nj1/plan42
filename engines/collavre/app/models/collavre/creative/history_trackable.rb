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

      def archived?
        archived_at.present?
      end

      def archive!
        mutate_archive_family(archived_at: Time.current, operation: "archive")
      end

      def unarchive!
        mutate_archive_family(archived_at: nil, operation: "unarchive")
      end

      private

      def mutate_archive_family(archived_at:, operation:)
        affected_ids = []
        self.class.transaction do
          targets = archive_targets(archived_at)
          affected_ids = targets.pluck(:id)
          parent_ids = targets.where.not(parent_id: nil).distinct.pluck(:parent_id)
          Creatives::History.record_bulk(targets, operation: operation) do
            targets.update_all(archived_at: archived_at)
          end
          refresh_archive_parent_progress(parent_ids)
        end
        CreativeTreeInvalidationJob.perform_later(affected_ids) if affected_ids.any?
      end

      def archive_targets(archived_at)
        scope = self.class.where(id: archive_family_ids)
        archived_at ? scope.where(archived_at: nil) : scope.where.not(archived_at: nil)
      end

      def refresh_archive_parent_progress(parent_ids)
        reload
        self.class.where(id: parent_ids).find_each do |affected_parent|
          Creatives::ProgressService.new(affected_parent).update_progress_from_children!
        end
      end

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
