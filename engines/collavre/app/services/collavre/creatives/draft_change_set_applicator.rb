# frozen_string_literal: true

module Collavre
  module Creatives
    class DraftChangeSetApplicator
      def initialize(change_set:, user:, plan:, skipped_change_ids: [])
        @change_set = change_set
        @user = user
        @plan = plan
        @skipped_change_ids = skipped_change_ids
        @id_map = {}
      end

      def call
        discard_skipped_changes
        History.track(**history_context) do
          Current.change_set = @change_set
          @plan.each { |creative, snapshot, attribute, change| apply(creative, snapshot, attribute, change) }
        end
        @change_set.update!(status: "applied", applied_at: Time.current)
        CreativeTreeInvalidationJob.perform_later(@change_set.creative_changes.pluck(:creative_id))
      end

      private

      def discard_skipped_changes
        changes = @change_set.creative_changes.where(id: @skipped_change_ids)
        stale_blob_ids = ActiveStorage::Attachment.where(record: changes, name: "history_files").pluck(:blob_id)
        changes.destroy_all
        History.schedule_blob_purge_rechecks(stale_blob_ids)
      end

      def history_context
        {
          actor: @change_set.user,
          origin: @change_set.origin,
          anchor: @change_set.anchor_creative,
          anchor_source: @change_set.anchor_source || :explicit,
          task: @change_set.task,
          topic: @change_set.topic,
          summary: @change_set.summary,
          status: "draft"
        }
      end

      def apply(creative, snapshot, attribute, change)
        remapped = remap_snapshot(snapshot)
        return apply_creation(remapped, change) unless creative
        return creative.update!(attribute => remapped[attribute]) if attribute

        SnapshotAssignment.call(creative, remapped)
        creative.save!
      end

      def apply_creation(snapshot, virtual_change)
        parent = Creative.find_by(id: snapshot["parent_id"])
        creative = Creative.new(user: parent&.user || @change_set.user || @user, parent: parent)
        SnapshotAssignment.call(creative, snapshot)
        creative.save!
        remap_virtual_change!(virtual_change, creative)
      end

      def remap_snapshot(snapshot)
        result = snapshot.deep_dup
        parent_id = result["parent_id"]
        result["parent_id"] = @id_map.fetch(parent_id, parent_id) if parent_id
        result
      end

      def remap_virtual_change!(virtual_change, creative)
        virtual_id = virtual_change.creative_id
        @id_map[virtual_id] = creative.id
        actual_change = @change_set.creative_changes.find_by!(creative_id: creative.id)
        actual_change.update!(position: virtual_change.position, conflict: virtual_change.conflict)
        virtual_change.destroy!
        remap_pending_references!(virtual_id, creative.id)
      end

      def remap_pending_references!(virtual_id, creative_id)
        @change_set.creative_changes.where.not(creative_id: creative_id).find_each do |change|
          attributes = {}
          %w[before after].each do |side|
            snapshot = change.public_send(side).deep_dup
            next unless snapshot["parent_id"] == virtual_id

            snapshot["parent_id"] = creative_id
            attributes[side] = snapshot
          end
          if change.previous_parent_id == virtual_id
            attributes[:previous_parent_id] = creative_id
          end
          change.update!(attributes) if attributes.any?
        end
      end
    end
  end
end
