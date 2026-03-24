module Collavre
  class Creative < ApplicationRecord
    module RealtimeBroadcastable
      extend ActiveSupport::Concern

      included do
        after_create_commit :broadcast_creative_created
        after_update_commit :broadcast_creative_updated
        after_destroy_commit :broadcast_creative_destroyed
      end

      private

      def broadcast_creative_created
        broadcast_creative_change(:created)
      end

      def broadcast_creative_updated
        broadcast_creative_change(:updated)
      end

      def broadcast_creative_destroyed
        broadcast_creative_change(:destroyed)
      end

      def broadcast_creative_change(action)
        roots = find_broadcast_roots
        return if roots.empty?

        payload = { action: action.to_s }

        case action
        when :destroyed
          payload[:creative] = { id: id, parent_id: parent_id }
        when :created, :updated
          payload[:creative] = broadcast_creative_data
          payload[:ancestors] = broadcast_ancestor_data
        end

        # Broadcast to every ancestor so any viewer at any level receives it
        Rails.logger.info "[CreativeBroadcast] #{action} creative #{id} -> broadcasting to #{roots.map(&:id)}"
        roots.each do |root|
          CreativesChannel.broadcast_to(root, payload)
        end
      end

      def find_broadcast_roots
        target = origin_id.present? ? (origin || self) : self
        # Broadcast to self + all ancestors, so anyone viewing any
        # level of the tree will receive the update
        ([target] + target.ancestors).filter_map do |creative|
          creative.effective_origin
        end.uniq
      rescue ActiveRecord::RecordNotFound
        []
      end

      def broadcast_creative_data
        {
          id: id,
          parent_id: parent_id,
          description: effective_description,
          description_raw_html: description,
          progress: progress,
          sequence: sequence,
          origin_id: origin_id,
          updated_at: updated_at&.iso8601
        }
      end

      def broadcast_ancestor_data
        ancestors.map do |anc|
          {
            id: anc.id,
            progress: anc.progress
          }
        end
      end
    end
  end
end
