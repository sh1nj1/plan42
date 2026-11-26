# frozen_string_literal: true

module Collavre
  module Creatives
    class ChangeSetVisibility
      attr_reader :user

      def initialize(user:)
        @user = user
        @user_id = user&.id
        @permission_filter = PermissionFilter.new(user: user)
        @historical_authorization = HistoricalSnapshotAuthorization.new(user: user)
      end

      def changes(changes)
        changes = changes.to_a
        existing_ids = Creative.unscoped.where(id: changes.map(&:creative_id)).pluck(:id).to_set
        visible_ids = readable_ids(existing_ids)
        visible_ids.merge(DraftLinkAuthorization.new(user: user).visible_removal_ids(changes))
        missing = changes.reject { |change| existing_ids.include?(change.creative_id) }
          .select { |change| historical_snapshot_visible?(change) }
        readable_parents = readable_ids(missing.filter_map { |change| historical_parent_id(change) })

        append_visible_descendants(missing, visible_ids, readable_parents)
        changes.select { |change| visible_ids.include?(change.creative_id) }
      end

      # Judges every change on its own, exactly as `changes([ change ])` would,
      # while resolving the lookups once for the whole list. Unlike #changes, a
      # visible change never lends its visibility to another one in the list,
      # so callers may split a long list into batches.
      def independent_changes(changes)
        changes = changes.to_a
        existing_ids = Creative.unscoped.where(id: changes.map(&:creative_id).uniq).pluck(:id).to_set
        orphaned = changes.reject { |change| existing_ids.include?(change.creative_id) }
          .select { |change| historical_snapshot_visible?(change) }.to_set
        readable = readable_ids(existing_ids.to_a + orphaned.filter_map { |change| historical_parent_id(change) })
        removable = removable_changes(changes)

        changes.select do |change|
          if existing_ids.include?(change.creative_id)
            readable.include?(change.creative_id) || removable.include?(change)
          else
            orphaned.include?(change) && readable.include?(historical_parent_id(change))
          end
        end
      end

      def nodes(creatives)
        creatives = creatives.to_a.uniq(&:id)
        visible_ids = readable_ids(creatives.map(&:id))
        creatives.select { |creative| visible_ids.include?(creative.id) }
      end

      def visible_id?(id)
        readable_ids([ id ]).include?(id)
      end

      def historical_snapshots_visible?(changes, state)
        @historical_authorization.snapshots_visible?(changes, state)
      end

      private

      # Draft link removals whose creative the viewer may still remove.
      def removable_changes(changes)
        authorization = DraftLinkAuthorization.new(user: user)
        candidates = changes.select { |change| authorization.removal_candidate?(change) }
        removable_ids = authorization.visible_removal_ids(candidates).to_set
        candidates.select { |change| removable_ids.include?(change.creative_id) }.to_set
      end

      def append_visible_descendants(missing, visible_ids, readable_parents)
        loop do
          additions = missing.select do |change|
            parent_id = historical_parent_id(change)
            !visible_ids.include?(change.creative_id) && parent_id &&
              (visible_ids.include?(parent_id) || readable_parents.include?(parent_id))
          end
          break if additions.empty?

          visible_ids.merge(additions.map(&:creative_id))
        end
      end

      def historical_parent_id(change)
        change.previous_parent_id || change.before["parent_id"] || change.after["parent_id"]
      end

      # A hard delete removes the Creative and its direct permission boundary.
      # The former parent alone cannot prove that another viewer could read the
      # deleted child (a closer no_access share may have overridden it), so only
      # the actor who performed that explicit deletion may inspect its snapshot.
      # AI deletes are archival and keep their live permission rows.
      def historical_snapshot_visible?(change)
        if change.change_set.status == "draft" && change.creative_id.negative? && change.before.empty?
          return historical_parent_id(change).present?
        end

        @user_id && change.change_set.user_id == @user_id
      end

      def readable_ids(ids)
        @permission_filter.readable_ids(ids).to_set
      end
    end
  end
end
