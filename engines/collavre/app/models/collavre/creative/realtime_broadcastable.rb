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
        broadcast_creative_change(:created, broadcast_payload)
      end

      def broadcast_creative_updated
        broadcast_creative_change(:updated, broadcast_payload)
      end

      def broadcast_creative_destroyed
        broadcast_creative_change(:destroyed, { id: id, parent_id: parent_id })
      end

      def broadcast_creative_change(action, data)
        target_users = find_broadcast_users
        # Exclude the user who made the change — their UI already reflects it
        current = Collavre.current_user
        target_users.reject! { |u| current && u.id == current.id }
        return if target_users.empty?

        payload = { action: action.to_s, creative: data }.to_json

        target_users.each do |target_user|
          Turbo::StreamsChannel.broadcast_action_to(
            [ target_user, :creative_tree ],
            action: :refresh_creative_tree,
            target: "creatives",
            attributes: { data: payload }
          )
        end
      end

      def broadcast_payload
        origin = begin
          effective_origin
        rescue StandardError
          self
        end

        data = {
          id: id,
          parent_id: parent_id,
          origin_id: origin_id,
          progress: progress,
          description_html: origin.effective_description,
          description_raw_html: description,
          has_children: children.exists?
        }

        # Include ancestor progress updates so clients can update
        # parent rows without a full tree refetch
        anc_progress = ancestors.map { |a| { id: a.id, progress: a.progress } }
        data[:ancestors] = anc_progress if anc_progress.any?

        data
      end

      def find_broadcast_users
        target = begin
          origin_id.present? && origin ? origin.effective_origin : effective_origin
        rescue ActiveRecord::RecordNotFound
          self
        end

        users = []
        users << target.user if target.user
        users.concat(target.all_shared_users.map(&:user))

        target.ancestors.each do |ancestor|
          users << ancestor.user if ancestor.user
          users.concat(ancestor.all_shared_users.map(&:user))
        end

        users.compact.uniq
      rescue StandardError => e
        Rails.logger.error "[CreativeBroadcast] Error finding users: #{e.message}"
        []
      end
    end
  end
end
