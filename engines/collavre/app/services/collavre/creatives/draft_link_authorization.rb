# frozen_string_literal: true

module Collavre
  module Creatives
    # Recheck link-specific invariants against current permissions and hierarchy
    # when an owner approves a captured draft.
    class DraftLinkAuthorization
      def self.supported_changes?(changes, mode)
        changes.none? do |change|
          change.operation == "destroy" && !(mode == :draft && change.before["origin_id"].present? && change.after.empty?)
        end
      end

      def initialize(user:)
        @user = user
      end

      def visible_removal_ids(changes)
        candidates = changes.select do |change|
          change.change_set.status == "draft" && change.operation == "destroy" &&
            change.before["origin_id"].present? && change.after.empty?
        end
        Creative.where(id: candidates.map(&:creative_id), user_id: @user&.id).select { |creative| removal_allowed?(creative) }.map(&:id)
      end

      def removal_allowed?(creative)
        creative&.origin_id.present? && creative.destroyable_by?(@user)
      end

      def creation_allowed?(snapshot, records, writable_ids:, virtual_ids:, anchor_id:)
        parent_id = snapshot["parent_id"]
        if parent_id&.negative?
          return false unless virtual_ids.include?(parent_id)
        else
          parent = records[parent_id || anchor_id]
          return false unless parent && !parent.read_only_source? && writable_ids.include?(parent.id)
        end
        return true unless snapshot["origin_id"]

        origin = records[snapshot["origin_id"]]
        return false unless origin && PermissionChecker.current_tree_allowed?(origin.id, @user)

        Reorderer.new(user: @user).validate_link!(origin: origin.effective_origin, parent: records[snapshot["parent_id"]])
        true
      rescue Reorderer::Error
        false
      end
    end
  end
end
