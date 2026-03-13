require "set"

module Collavre
  module Creatives
    class ProgressService
      def initialize(creative)
        @creative = creative
      end

      def update_progress_from_children!
        active_children = creative.children.active
        if active_children.any?
          # Use Ruby calculation to get effective progress (handling delegation for linked creatives)
          # instead of SQL average which reads potentially stale DB columns.
          new_progress = active_children.map(&:progress).sum.to_f / active_children.size
          creative.update(progress: new_progress)
        else
          creative.update(progress: 0)
        end
      end

      def update_parent_progress!(visited_ids = Set.new)
        return if visited_ids.include?(creative.id)
        visited_ids.add(creative.id)

        creative.linked_creatives.find_each do |linked|
          # Linked creatives delegate progress to origin.
          # We don't update them directly (forbidden by validation).
          # We must ensure their PARENTS are updated.
          # Recurse with visited_ids to prevent cycles.
          ProgressService.new(linked).update_parent_progress!(visited_ids)
        end
        parent = creative.parent
        return unless parent

        begin
          parent.reload
        rescue ActiveRecord::RecordNotFound
          return
        end
        active_children = parent.children.active
        new_progress = if active_children.any?
                         active_children.map(&:progress).sum.to_f / active_children.size
        else
                         0
        end

        # Avoid infinite recursion
        if (parent.progress - new_progress).abs > 0.0001
          parent.update(progress: new_progress)
        end
      end

      def progress_for_tags(tag_ids, user)
        return creative.progress if tag_ids.blank?
        return nil if creative.archived?

        tag_ids = Array(tag_ids).map(&:to_s)
        visible_children = creative.children_with_permission(user).select { |c| !c.archived? }
        child_values = visible_children.map do |child|
          self.class.new(child).progress_for_tags(tag_ids, user)
        end.compact

        if child_values.any?
          child_values.sum.to_f / child_values.size
        else
          own_label_ids = creative.tags.pluck(:label_id).map(&:to_s)
          if (own_label_ids & tag_ids).any?
            visible_children.any? ? 1.0 : creative.progress
          end
        end
      end

      # `tagged_ids` should be a Set of creative IDs tagged with the plan.
      def progress_for_plan(tagged_ids)
        return nil if creative.archived?

        child_values = creative.children.active.map do |child|
          self.class.new(child).progress_for_plan(tagged_ids)
        end.compact

        if child_values.any?
          child_values.sum.to_f / child_values.size
        elsif tagged_ids.include?(creative.id)
          creative.children.any? ? 1.0 : creative.progress
        end
      end

      private

      attr_reader :creative
    end
  end
end
