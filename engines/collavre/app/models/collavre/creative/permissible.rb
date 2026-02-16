module Collavre
  class Creative < ApplicationRecord
    module Permissible
      extend ActiveSupport::Concern

      included do
        has_many :creative_shares, class_name: "Collavre::CreativeShare", dependent: :destroy
        has_many :creative_shares_caches, class_name: "Collavre::CreativeSharesCache", dependent: :delete_all

        after_commit :rebuild_permission_cache, if: :saved_change_to_parent_id?, unless: :destroyed?
        after_commit :cache_owner_permission, on: :create
        after_commit :update_owner_cache, if: :saved_change_to_user_id?, unless: :destroyed?
      end

      def has_permission?(user, required_permission = :read)
        Collavre::Creatives::PermissionChecker.new(self, user).allowed?(required_permission)
      end

      # Returns only children for which the user has at least the given permission
      def children_with_permission(user = nil, min_permission = :read)
        user ||= Collavre.current_user
        children_scope = effective_origin(Set.new).children
        children_ids = children_scope.pluck(:id)
        return [] if children_ids.empty?

        min_rank = CreativeShare.permissions[min_permission.to_s]
        accessible_ids = Set.new

        if user
          user_entries = CreativeSharesCache
            .where(creative_id: children_ids, user_id: user.id)
            .pluck(:creative_id, :permission)

          user_has_entry = Set.new
          user_entries.each do |cid, perm|
            user_has_entry << cid
            perm_rank = CreativeSharesCache.permissions[perm]
            if perm_rank && perm_rank >= min_rank && perm_rank != CreativeSharesCache.permissions[:no_access]
              accessible_ids << cid
            end
          end

          public_accessible = CreativeSharesCache
            .where(creative_id: children_ids, user_id: nil)
            .where("permission >= ?", min_rank)
            .where.not(permission: :no_access)
            .pluck(:creative_id)
          accessible_ids.merge(public_accessible - user_has_entry.to_a)

          owned_ids = children_scope.where(user_id: user.id).pluck(:id)
          accessible_ids.merge(owned_ids)
        else
          accessible_ids = CreativeSharesCache
            .where(creative_id: children_ids, user_id: nil)
            .where("permission >= ?", min_rank)
            .where.not(permission: :no_access)
            .pluck(:creative_id)
            .to_set
        end

        children_scope.where(id: accessible_ids.to_a).order(:sequence).to_a
      end

      def all_shared_users(required_permission = :no_access)
        base_creative = effective_origin(Set.new)
        ancestor_ids = [ base_creative.id ] + base_creative.ancestors.pluck(:id)
        required_permission_level = CreativeShare.permissions.fetch(required_permission.to_s)

        shares = CreativeShare.where(creative_id: ancestor_ids).includes(:user)
        shares_for_user_hash = shares.group_by(&:user_id)

        shares_for_user_hash.filter_map do |_user_id, user_shares|
          closest_share = CreativeShare.closest_parent_share(ancestor_ids, user_shares)
          next unless closest_share

          closest_permission_level = CreativeShare.permissions.fetch(closest_share.permission.to_s)
          next if closest_permission_level < required_permission_level

          closest_share
        end
      end

      private

      def rebuild_permission_cache
        PermissionCacheJob.perform_later(:rebuild_for_creative, creative_id: id)
      end

      def cache_owner_permission
        PermissionCacheJob.perform_later(:cache_owner, creative_id: id)
      end

      def update_owner_cache
        old_user_id, new_user_id = saved_change_to_user_id
        PermissionCacheJob.perform_later(:update_owner,
          creative_id: id,
          old_user_id: old_user_id,
          new_user_id: new_user_id
        )
      end
    end
  end
end
