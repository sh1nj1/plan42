module Collavre
  class Creative < ApplicationRecord
    module Permissible
      extend ActiveSupport::Concern

      # Single declarative registry of which persisted-attribute changes
      # invalidate the permission cache, and how each is rebuilt. A single
      # after_commit dispatcher intersects saved_changes.keys with this map so
      # a new mutation path can never silently skip a required rebuild.
      #
      #   :rebuild       -> rebuild_for_creative (self + descendant subtree)
      #   :rebuild_owner -> update_owner (move the owner cache entry)
      #
      # origin_id is immutable after create (see Linkable#attr_readonly), so its
      # entry only fires on link creation and is defensive.
      PERMISSION_INVALIDATING_ATTRIBUTES = {
        "parent_id" => :rebuild,
        "user_id"   => :rebuild_owner,
        "origin_id" => :rebuild
      }.freeze

      included do
        has_many :creative_shares, class_name: "Collavre::CreativeShare", dependent: :destroy
        has_many :creative_shares_caches, class_name: "Collavre::CreativeSharesCache", dependent: :delete_all

        after_commit :dispatch_permission_cache_invalidation, unless: :destroyed?
        after_commit :cache_owner_permission, on: :create
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

      def find_ai_agent(required_permission = :write)
        base_creative = effective_origin(Set.new)
        ancestor_ids = [ base_creative.id ] + base_creative.ancestors.pluck(:id)
        required_permission_level = CreativeShare.permissions.fetch(required_permission.to_s)

        shares = CreativeShare.where(creative_id: ancestor_ids)
                              .joins(:user).merge(User.ai_agents)
                              .includes(:user)
        shares_for_user_hash = shares.group_by(&:user_id)

        shares_for_user_hash.each_value do |user_shares|
          closest_share = CreativeShare.closest_parent_share(ancestor_ids, user_shares)
          next unless closest_share

          closest_permission_level = CreativeShare.permissions.fetch(closest_share.permission.to_s)
          next if closest_permission_level < required_permission_level

          return closest_share.user
        end

        nil
      end

      private

      # Single dispatch point for permission-cache invalidation. Intersects the
      # attributes that actually changed with PERMISSION_INVALIDATING_ATTRIBUTES
      # and enqueues each distinct rebuild exactly once.
      def dispatch_permission_cache_invalidation
        operations = (saved_changes.keys & PERMISSION_INVALIDATING_ATTRIBUTES.keys)
          .map { |attr| PERMISSION_INVALIDATING_ATTRIBUTES[attr] }
          .uniq
        return if operations.empty?

        operations.each { |operation| run_permission_cache_operation(operation) }
      end

      def run_permission_cache_operation(operation)
        case operation
        when :rebuild
          PermissionCacheJob.perform_later(:rebuild_for_creative, creative_id: id)
        when :rebuild_owner
          old_user_id, new_user_id = saved_changes["user_id"]
          PermissionCacheJob.perform_later(:update_owner,
            creative_id: id,
            old_user_id: old_user_id,
            new_user_id: new_user_id
          )
        end
      end

      def cache_owner_permission
        PermissionCacheJob.perform_later(:cache_owner, creative_id: id)
      end
    end
  end
end
