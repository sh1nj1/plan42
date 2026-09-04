# frozen_string_literal: true

module Collavre
  module Creatives
    class PropagatedChangeAuthorization
      def initialize(changes:, records:, writable_source_ids:)
        @changes = changes
        @records = records
        @writable_source_ids = writable_source_ids
      end

      def call
        attributes = linked_archive_attributes
        add_parent_progress_attributes(attributes)
        add_linked_progress_attributes(attributes)
        attributes
      end

      private

      def linked_archive_attributes
        changes.each_with_object({}) do |change, attributes|
          creative = records[change.creative_id]
          next unless creative&.origin_id.in?(writable_source_ids)
          next unless transition_only?(change, "archived_at", %w[archive unarchive])

          attributes[change.id] = "archived_at"
        end
      end

      def add_parent_progress_attributes(attributes)
        parent_ids = attributes.keys.flat_map { |id| snapshot_parent_ids(change_by_id.fetch(id)) }.to_set
        loop do
          additions = parent_progress_additions(parent_ids, attributes)
          break if additions.empty?

          register_parent_progress(additions, attributes, parent_ids)
        end
      end

      def add_linked_progress_attributes(attributes)
        source_ids = changes.filter_map do |change|
          change.creative_id if writable_source_ids.include?(change.creative_id) &&
            change.before["progress"] != change.after["progress"]
        end.to_set
        parent_ids = direct_parent_ids(source_ids) | linked_parent_ids(source_ids)
        loop do
          additions = parent_progress_additions(parent_ids, attributes)
          break if additions.empty?

          register_parent_progress(additions, attributes, parent_ids)
          parent_ids.merge(linked_parent_ids(additions.map(&:creative_id)))
        end
      end

      def linked_parent_ids(source_ids)
        Creative.where(origin_id: source_ids).where.not(parent_id: nil).distinct.pluck(:parent_id).to_set
      end

      def direct_parent_ids(source_ids)
        changes.flat_map do |change|
          next unless source_ids.include?(change.creative_id)

          snapshot_parent_ids(change)
        end.compact.to_set
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
          parent_ids.merge(snapshot_parent_ids(change))
        end
      end

      def snapshot_parent_ids(change)
        [ change.before["parent_id"], change.after["parent_id"] ].compact
      end

      def transition_only?(change, attribute, operations)
        operations.include?(change.operation) && change.before[attribute] != change.after[attribute] &&
          change.before.except(attribute) == change.after.except(attribute)
      end

      def change_by_id
        @change_by_id ||= changes.index_by(&:id)
      end

      attr_reader :changes, :records, :writable_source_ids
    end
  end
end
