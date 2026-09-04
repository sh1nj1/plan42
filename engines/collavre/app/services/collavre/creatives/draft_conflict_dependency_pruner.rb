# frozen_string_literal: true

module Collavre
  module Creatives
    class DraftConflictDependencyPruner
      def initialize(changes:, records:, skipped_change_ids:)
        @changes = changes
        @records = records
        @discard_change_ids = skipped_change_ids.dup
      end

      def call(plan)
        source_ids = skipped_archive_changes.map(&:creative_id).to_set
        return discard_change_ids if source_ids.empty?

        collect_archive_family(source_ids)
        collect_progress_chain
        plan.reject! { |_creative, _snapshot, _attribute, change| discard_change_ids.include?(change.id) }
        discard_change_ids
      end

      private

      attr_reader :changes, :records, :discard_change_ids

      def skipped_archive_changes
        changes.select { |change| discard_change_ids.include?(change.id) && archival_transition?(change) }
      end

      def collect_archive_family(family_ids)
        loop do
          additions = changes.select do |change|
            archive_family_addition?(change, family_ids)
          end
          break if additions.empty?

          additions.each do |change|
            family_ids << change.creative_id
            discard_change_ids << change.id
          end
        end
      end

      def archive_family_addition?(change, family_ids)
        return false unless archival_transition?(change) && !family_ids.include?(change.creative_id)

        creative = records[change.creative_id]
        parent_id = change.before["parent_id"] || change.after["parent_id"]
        family_ids.include?(parent_id) || family_ids.include?(creative&.origin_id)
      end

      def collect_progress_chain
        parent_ids = discard_change_ids.filter_map do |change_id|
          change = changes_by_id[change_id]
          records[change&.creative_id]&.parent_id
        end.to_set
        loop do
          additions = changes.select do |change|
            !discard_change_ids.include?(change.id) && parent_ids.include?(change.creative_id) && progress_only?(change)
          end
          break if additions.empty?

          additions.each do |change|
            discard_change_ids << change.id
            parent_ids << records[change.creative_id]&.parent_id
          end
        end
      end

      def archival_transition?(change)
        change.operation.in?(%w[archive unarchive]) &&
          change.before["archived_at"] != change.after["archived_at"]
      end

      def progress_only?(change)
        change.operation == "update" && change.before["progress"] != change.after["progress"] &&
          change.before.except("progress") == change.after.except("progress")
      end

      def changes_by_id
        @changes_by_id ||= changes.index_by(&:id)
      end
    end
  end
end
