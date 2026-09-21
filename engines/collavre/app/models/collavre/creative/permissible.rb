module Collavre
  class Creative < ApplicationRecord
    module Permissible
      extend ActiveSupport::Concern

      # Single declarative registry of which persisted-attribute changes
      # invalidate the permission cache, and how each is rebuilt. A single
      # after_commit dispatcher maps the accumulated changes through this map so
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

        after_save :accumulate_permission_cache_changes
        after_update :reconcile_topic_read_pointers_for_owner_change, if: :saved_change_to_user_id?
        after_commit :dispatch_permission_cache_invalidation, unless: :destroyed?
        after_commit :cache_owner_permission, on: :create
        after_rollback :clear_accumulated_permission_changes
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

        # The deny-invariant (owner wins → user entry, incl. a no_access deny,
        # beats public → effective-origin resolution) now lives in exactly one
        # place: PermissionFilter. This site used to re-implement it inline.
        accessible_ids = Collavre::Creatives::PermissionFilter.new(user: user)
          .readable_ids(children_ids, min_permission: min_permission)

        # readable_ids gates a linked shell on its origin being readable AND the
        # viewer being able to see the shell's placement (owns it, or it sits in
        # a subtree shared with the viewer). Listing one's OWN tree keeps the
        # prior policy that a viewer always sees their own children — including a
        # shell they own whose origin is no longer shared with them — so union
        # those owned rows back in. (Owner has admin, so this is rank-independent.)
        accessible_ids |= children_scope.where(user_id: user.id).pluck(:id) if user

        children_scope.where(id: accessible_ids).order(:sequence).to_a
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

      # Accumulate permission-affecting changes across every save in the
      # transaction. after_commit sees only the *final* save's saved_changes, so
      # if a permission attribute changes in one save and a later same-
      # transaction save of this record touches only untracked columns, that
      # permission change is clobbered out of saved_changes and a saved_changes-
      # gated dispatcher would skip the rebuild, leaving the permission cache
      # stale (fail-open, with no TTL/self-heal). Merging each save's changes
      # keeps the invariant regardless of save ordering. This mirrors the fail-
      # closed intent of the CreativeShare fix (#1393 / 00502d7d); it is
      # centralized here via cross-save accumulation rather than an
      # unconditional refresh so that permission-irrelevant Creative updates
      # (progress rollup, description edits — a hot write path) stay cheap.
      #
      # No production path performs two real saves touching a permission
      # attribute then an untracked column on one Creative in a single
      # transaction today (the reorderer re-saves :sequence via update_column,
      # which does not run changes_applied and so preserves saved_changes), so
      # this is a defensive/latent fix. Note: update_column bypasses this
      # callback too, which is why the reorderer's parent change still refreshes.
      def accumulate_permission_cache_changes
        changes = saved_changes.slice(*PERMISSION_INVALIDATING_ATTRIBUTES.keys)
        return if changes.empty?

        @accumulated_permission_changes ||= {}
        changes.each do |attribute, (old_value, new_value)|
          existing = @accumulated_permission_changes[attribute]
          # Keep the earliest "old" and the latest "new" across saves.
          @accumulated_permission_changes[attribute] = [ existing ? existing.first : old_value, new_value ]
        end
      end

      def clear_accumulated_permission_changes
        @accumulated_permission_changes = nil
      end

      # Single dispatch point for permission-cache invalidation. Maps the
      # accumulated permission-attribute changes through
      # PERMISSION_INVALIDATING_ATTRIBUTES and enqueues each distinct rebuild
      # exactly once.
      def dispatch_permission_cache_invalidation
        accumulated = @accumulated_permission_changes || {}
        clear_accumulated_permission_changes

        operations = accumulated.keys
          .map { |attr| PERMISSION_INVALIDATING_ATTRIBUTES[attr] }
          .uniq
        return if operations.empty?

        operations.each { |operation| run_permission_cache_operation(operation, accumulated) }
      end

      def run_permission_cache_operation(operation, accumulated)
        case operation
        when :rebuild
          PermissionCacheJob.perform_later(:rebuild_for_creative, creative_id: id)
        when :rebuild_owner
          old_user_id, new_user_id = accumulated["user_id"]
          PermissionCacheJob.perform_later(:update_owner,
            creative_id: id,
            old_user_id: old_user_id,
            new_user_id: new_user_id
          )
        end
      end

      # Topic moves preserve a reader's cursor on the source until that reader
      # gains access to the destination. A Creative ownership transfer is one
      # such grant, but it does not touch CreativeShare, so reconcile the new
      # owner's durable pointers here as well.
      def reconcile_topic_read_pointers_for_owner_change
        return unless user_id

        CreativeShare.reconcile_topic_read_pointers(effective_origin.id, user_ids: [ user_id ])
      end

      def cache_owner_permission
        PermissionCacheJob.perform_later(:cache_owner, creative_id: id)
      end
    end
  end
end
