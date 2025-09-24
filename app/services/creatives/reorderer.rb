module Creatives
  class Reorderer
    class Error < StandardError; end

    LinkDropResult = Struct.new(:new_creative, :parent, :direction, keyword_init: true)

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

    def link_drop(dragged_id:, target_id:, direction:)
      dragged, target = fetch_creatives(dragged_id, target_id)
      validate_direction!(direction)
      raise Error, "Invalid creatives" unless dragged && target

      origin = dragged.effective_origin
      new_parent = direction == "child" ? target : target.parent

      new_creative = nil
      Creative.transaction do
        new_creative = Creative.create!(
          origin_id: origin.id,
          parent: new_parent,
          user: new_parent&.user || user
        )

        siblings = sibling_scope(new_parent)
        siblings.delete(new_creative)

        if direction == "child"
          siblings << new_creative
        else
          target_index = siblings.index(target) || 0
          insert_index = direction == "up" ? target_index : target_index + 1
          insert_index = [ [ insert_index, 0 ].max, siblings.size ].min
          siblings.insert(insert_index, new_creative)
        end

        resequence!(siblings)
      end

      LinkDropResult.new(new_creative: new_creative, parent: new_parent, direction: direction)
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

    def sibling_scope(parent)
      parent ? parent.children.order(:sequence).to_a : Creative.roots.order(:sequence).to_a
    end

    def resequence!(creatives)
      creatives.each_with_index do |creative, idx|
        creative.update_column(:sequence, idx)
      end
    end
  end
end
