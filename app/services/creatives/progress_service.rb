require "set"

module Creatives
  class ProgressService
    def self.recalculate_all!
      Creative.roots.find_each { |root| new(root).recalculate_subtree! }
    end

    def initialize(creative)
      @creative = creative
    end

    def recalculate_subtree!
      if creative.origin_id.nil?
        creative.children.each { |child| self.class.new(child).recalculate_subtree! }
        if creative.children.any?
          creative.update(progress: creative.children.average(:progress) || 0)
        end
      else
        self.class.new(creative.origin).recalculate_subtree!
      end
    end

    def update_parent_progress!
      creative.linked_creatives.update_all(progress: creative[:progress])
      parent = creative.parent
      return unless parent

      parent.reload
      new_progress = if parent.children.any?
                       parent.children.map(&:progress).sum.to_f / parent.children.size
      else
                       0
      end
      parent.update(progress: new_progress)
    end

    def progress_for_tags(tag_ids, user)
      return creative.progress if tag_ids.blank?

      tag_ids = Array(tag_ids).map(&:to_s)
      visible_children = creative.children_with_permission(user)
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
      child_values = creative.children.map do |child|
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
