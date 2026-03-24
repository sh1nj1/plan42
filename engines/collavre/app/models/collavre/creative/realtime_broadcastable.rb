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
        root = find_broadcast_root
        return unless root

        payload = { action: action.to_s }

        case action
        when :destroyed
          payload[:creative] = { id: id, parent_id: parent_id }
        when :created, :updated
          payload[:creative] = broadcast_creative_data
          payload[:ancestors] = broadcast_ancestor_data
        end

        CreativesChannel.broadcast_to(root, payload)
      end

      def find_broadcast_root
        # For linked creatives, broadcast to the origin's root
        target = origin_id.present? ? (origin || self) : self
        # Walk up to the root using closure_tree
        root = target.root
        root&.effective_origin
      rescue ActiveRecord::RecordNotFound
        nil
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
