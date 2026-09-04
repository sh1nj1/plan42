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
        missing = changes.reject { |change| existing_ids.include?(change.creative_id) }
          .select { |change| historical_snapshot_visible?(change) }
        readable_parents = readable_ids(missing.filter_map { |change| historical_parent_id(change) })

        append_visible_descendants(missing, visible_ids, readable_parents)
        changes.select { |change| visible_ids.include?(change.creative_id) }
      end

      def nodes(creatives)
        creatives = creatives.to_a.uniq(&:id)
        visible_ids = readable_ids(creatives.map(&:id))
        creatives.select { |creative| visible_ids.include?(creative.id) }
      end

      def visible_id?(id)
        readable_ids([ id ]).include?(id)
      end

      def historical_before_visible?(changes)
        @historical_authorization.before_visible?(changes)
      end

      private

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
