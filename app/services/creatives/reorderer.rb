module Creatives
  class Reorderer
    class Error < StandardError; end

    LinkDropResult = Struct.new(:creative_link, :origin, :parent, :direction, keyword_init: true)

    def initialize(user:)
      @user = user
    end

    def reorder(dragged_id:, target_id:, direction:)
      dragged, target = fetch_creatives(dragged_id, target_id)
      validate_direction!(direction)
      raise Error, "Invalid creatives" unless dragged && target

      if direction == "child"
        reorder_as_child(dragged, target)
      else
        reorder_as_sibling(dragged, target, direction)
      end

      true
    end

    def reorder_multiple(dragged_ids:, target_id:, direction:)
      ids = Array(dragged_ids).map(&:presence).compact
      validate_direction!(direction)
      raise Error, "Invalid creatives" if ids.empty?

      target = Creative.find_by(id: target_id)
      raise Error, "Invalid creatives" unless target

      dragged_lookup = Creative.where(id: ids).index_by { |creative| creative.id.to_s }
      ordered_dragged = ids.map { |id| dragged_lookup[id.to_s] }.compact
      raise Error, "Invalid creatives" unless ordered_dragged.size == ids.size

      if ordered_dragged.any? { |creative| creative.id == target.id }
        raise Error, "Invalid creatives"
      end

      target_ancestor_ids = target.ancestors.pluck(:id)
      if ordered_dragged.any? { |creative| target_ancestor_ids.include?(creative.id) }
        raise Error, "Invalid creatives"
      end

      if direction == "child"
        reorder_multiple_as_child(ordered_dragged, target)
      else
        reorder_multiple_as_sibling(ordered_dragged, target, direction)
      end

      true
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      raise Error, e.message
    end

    def link_drop(dragged_id:, target_id:, direction:)
      dragged, target = fetch_creatives(dragged_id, target_id)
      validate_direction!(direction)
      raise Error, "Invalid creatives" unless dragged && target

      origin = dragged.effective_origin
      new_parent = direction == "child" ? target : target.parent

      raise Error, "Parent required for link" unless new_parent.present?

      # Check for circular reference
      origin_descendant_ids = origin.self_and_descendants.pluck(:id)
      new_parent.self_and_ancestors.each do |ancestor|
        ancestor_origin_id = ancestor.origin_id.presence || ancestor.id
        if origin_descendant_ids.include?(ancestor_origin_id)
          raise Error, "Invalid creatives"
        end
      end

      # Check if link already exists
      existing_link = CreativeLink.find_by(parent_id: new_parent.id, origin_id: origin.id)
      raise Error, "Link already exists" if existing_link

      creative_link = nil
      CreativeLink.transaction do
        # Calculate sequence for the new link
        sequence = calculate_link_sequence(new_parent, target, direction)

        creative_link = CreativeLink.create!(
          parent_id: new_parent.id,
          origin_id: origin.id,
          created_by: user,
          sequence: sequence
        )
      end

      LinkDropResult.new(creative_link: creative_link, origin: origin, parent: new_parent, direction: direction)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
      raise Error, e.message
    end

    private

    attr_reader :user

    def fetch_creatives(dragged_id, target_id)
      [ Creative.find_by(id: dragged_id), Creative.find_by(id: target_id) ]
    end

    def validate_direction!(direction)
      raise Error, "Invalid direction" unless %w[up down child].include?(direction)
    end

    def reorder_as_child(dragged, target)
      dragged.update!(parent: target)
      siblings = target.children.order(:sequence).to_a
      siblings.delete(dragged)
      siblings << dragged
      resequence!(siblings)
    end

    def reorder_as_sibling(dragged, target, direction)
      if dragged.parent != target.parent
        dragged.update!(parent: target.parent)
      end

      siblings = sibling_scope(dragged.parent)
      siblings.delete(dragged)
      target_index = siblings.index(target)
      new_index = direction == "up" ? target_index : target_index.to_i + 1
      siblings.insert(new_index, dragged)
      resequence!(siblings)
    end

    def reorder_multiple_as_child(dragged_creatives, target)
      Creative.transaction do
        siblings = target.children.order(:sequence).to_a
        dragged_creatives.each do |dragged|
          siblings.delete(dragged)
        end

        dragged_creatives.each do |dragged|
          dragged.update!(parent: target)
        end

        siblings.concat(dragged_creatives)
        resequence!(siblings)
      end
    end

    def reorder_multiple_as_sibling(dragged_creatives, target, direction)
      Creative.transaction do
        parent = target.parent
        siblings = sibling_scope(parent)
        dragged_creatives.each do |dragged|
          siblings.delete(dragged)
        end

        dragged_creatives.each do |dragged|
          dragged.update!(parent: parent)
        end

        target_index = siblings.index(target)
        raise Error, "Invalid creatives" if target_index.nil?

        insert_index = direction == "up" ? target_index : target_index + 1
        insert_index = [ [ insert_index, 0 ].max, siblings.size ].min

        siblings.insert(insert_index, *dragged_creatives)
        resequence!(siblings)
      end
    end

    def sibling_scope(parent)
      parent ? parent.children.order(:sequence).to_a : Creative.roots.order(:sequence).to_a
    end

    def resequence!(creatives)
      creatives.each_with_index do |creative, idx|
        creative.update_column(:sequence, idx)
      end
    end

    def calculate_link_sequence(parent, target, direction)
      # Get all children (actual + linked) and find position
      actual_children = parent.children.order(:sequence).to_a
      linked_origins = CreativeLink.where(parent_id: parent.id)
        .order(:sequence)
        .includes(:origin)
        .map(&:origin)

      all_children = (actual_children + linked_origins).sort_by(&:sequence)

      if direction == "child"
        # Add at end
        (all_children.last&.sequence || -1) + 1
      else
        target_index = all_children.index { |c| c.id == target.id }
        return 0 unless target_index

        if direction == "up"
          target_index > 0 ? all_children[target_index - 1].sequence + 1 : 0
        else
          target.sequence + 1
        end
      end
    end
  end
end
