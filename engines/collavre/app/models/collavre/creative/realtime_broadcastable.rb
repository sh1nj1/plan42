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
        target_users = find_broadcast_users
        return if target_users.empty?

        Rails.logger.info "[CreativeBroadcast] #{action} creative #{id} -> broadcasting to users #{target_users.map(&:id)}"

        # Exclude the user who made the change — their UI already reflects it
        current = Collavre.current_user
        target_users.reject! { |u| current && u.id == current.id }
        return if target_users.empty?

        target_users.each do |target_user|
          Turbo::StreamsChannel.broadcast_action_to(
            [ target_user, :creative_tree ],
            action: :refresh_creative_tree,
            target: "creatives",
            attributes: {
              "creative-id": id.to_s,
              "change-action": action.to_s
            }
          )
        end
      end

      def find_broadcast_users
        # Find the effective origin (for linked creatives)
        target = begin
          origin_id.present? && origin ? origin.effective_origin : effective_origin
        rescue ActiveRecord::RecordNotFound
          self
        end

        # Collect all users who might see this creative:
        # 1. Owner of the creative
        # 2. All users with shares on this creative or its ancestors
        users = []
        users << target.user if target.user

        # Shared users on the creative itself
        users.concat(target.all_shared_users.map(&:user))

        # Also check ancestor shares (viewers at parent level)
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
