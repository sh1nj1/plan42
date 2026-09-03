# frozen_string_literal: true

module Collavre
  module Creatives
    class PropagatedChangeAuthorization
      def initialize(changes:, records:, writable_origin_ids:)
        @changes = changes
        @records = records
        @writable_origin_ids = writable_origin_ids
      end

      def call
        attributes = linked_archive_attributes
        add_parent_progress_attributes(attributes)
        attributes
      end

      private

      def linked_archive_attributes
        changes.each_with_object({}) do |change, attributes|
          creative = records[change.creative_id]
          next unless creative&.origin_id.in?(writable_origin_ids)
          next unless transition_only?(change, "archived_at", %w[archive unarchive])

          attributes[change.id] = "archived_at"
        end
      end

      def add_parent_progress_attributes(attributes)
        parent_ids = attributes.keys.filter_map { |id| records[change_by_id.fetch(id).creative_id]&.parent_id }.to_set
        loop do
          additions = parent_progress_additions(parent_ids, attributes)
          break if additions.empty?

          register_parent_progress(additions, attributes, parent_ids)
        end
      end

      def parent_progress_additions(parent_ids, attributes)
        changes.filter_map do |change|
          creative = records[change.creative_id]
          change if !attributes.key?(change.id) && parent_ids.include?(creative&.id) &&
            transition_only?(change, "progress", %w[update])
        end
      end

      def register_parent_progress(additions, attributes, parent_ids)
        additions.each do |change|
          attributes[change.id] = "progress"
          parent_ids << records.fetch(change.creative_id).parent_id
        end
      end

      def transition_only?(change, attribute, operations)
        operations.include?(change.operation) && change.before[attribute] != change.after[attribute] &&
          change.before.except(attribute) == change.after.except(attribute)
      end

      def change_by_id
        @change_by_id ||= changes.index_by(&:id)
      end

      attr_reader :changes, :records, :writable_origin_ids
    end
  end
end
