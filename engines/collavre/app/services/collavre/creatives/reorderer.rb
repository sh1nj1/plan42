module Collavre
module Creatives
  class Reorderer
    class Error < StandardError; end
    # Raised when the acting user lacks the permission required to perform the
    # move. Subclasses Error so existing `rescue Reorderer::Error` call sites
    # keep failing closed; controllers rescue it first to answer 403 vs 422.
    class PermissionError < Error; end

    LinkDropResult = Struct.new(:new_creative, :parent, :direction, keyword_init: true)

    def initialize(user:)
      @user = user
    end

    def reorder(dragged_id:, target_id:, direction:)
      dragged, target = fetch_creatives(dragged_id, target_id)
      validate_direction!(direction)
      raise Error, "Invalid creatives" unless dragged && target

      authorize_move!([ dragged ], target, direction)

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

      target = Creative.find_by(id: target_id)
      raise Error, "Invalid creatives" unless target

      ordered_dragged = resolve_selection(ids, target)
      # Every dragged creative is checked before any mutation runs, so a single
      # unauthorized id rejects the whole batch and leaves the DB untouched.
      # Authorizing ahead of the ancestor check also keeps a caller without
      # access from reading tree shape out of the 403-vs-422 split.
      authorize_move!(ordered_dragged, target, direction)
      validate_not_target_ancestors!(ordered_dragged, target)

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

      authorize_link_drop!(dragged, target, direction)

      origin = dragged.effective_origin
      new_parent = direction == "child" ? target : target.parent
      validate_link_placement!(origin, new_parent)

      new_creative = insert_link_shell!(origin, target, new_parent, direction)

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

    # A move rewrites the dragged creatives themselves and the child ordering of
    # the container they land in, so both need :write. For "child" the container
    # is the target; for "up"/"down" it is the target's parent (nil at root, in
    # which case the target itself is the only anchor we can check).
    def authorize_move!(dragged_creatives, target, direction)
      new_parent = direction == "child" ? target : target.parent
      subjects = dragged_creatives + [ target, new_parent ].compact
      require_permissions!(subjects, :write)
    end

    # A link drop never mutates the dragged creative - it creates a new shell
    # pointing at the same origin - so :read on the source is enough. The
    # container that receives the shell still needs :write.
    def authorize_link_drop!(dragged, target, direction)
      require_permissions!([ dragged ], :read)

      new_parent = direction == "child" ? target : target.parent
      require_permissions!([ target, new_parent ].compact, :write)
    end

    # PermissionChecker resolves a link shell to its origin, which is correct
    # for content access but insufficient for a tree mutation: write access to
    # an origin must not authorize moving somebody else's private shell or
    # inserting below it. PermissionFilter applies both origin access and the
    # shell-placement gate, and batches the subjects for multi-drag.
    def require_permissions!(creatives, level)
      ids = creatives.uniq(&:id).map(&:id)
      allowed_ids = Collavre::Creatives::PermissionFilter.new(user: user).readable_ids(ids, min_permission: level)
      return if allowed_ids.size == ids.size

      raise PermissionError, "Permission denied"
    end

    # Resolves the dragged ids into Creatives in selection order, rejecting any
    # selection that cannot produce a valid tree: empty, duplicated, containing
    # an unknown id, or containing the target itself.
    def resolve_selection(ids, target)
      raise Error, "Invalid creatives" if ids.empty? || ids.map(&:to_s).uniq.size != ids.size

      lookup = Creative.where(id: ids).index_by { |creative| creative.id.to_s }
      ordered = ids.map { |id| lookup[id.to_s] }.compact
      raise Error, "Invalid creatives" unless ordered.size == ids.size
      raise Error, "Invalid creatives" if ordered.any? { |creative| creative.id == target.id }

      ordered
    end

    # Dropping onto a descendant of the selection would make the target its own
    # ancestor.
    def validate_not_target_ancestors!(dragged_creatives, target)
      target_ancestor_ids = target.ancestors.pluck(:id)
      return if dragged_creatives.none? { |creative| target_ancestor_ids.include?(creative.id) }

      raise Error, "Invalid creatives"
    end

    # Same cycle guard for links, compared on origin ids so a link shell sitting
    # in the ancestor chain is caught alongside a real creative.
    def validate_link_placement!(origin, new_parent)
      return if new_parent.blank?

      origin_descendant_ids = origin.self_and_descendants.pluck(:id)

      new_parent.self_and_ancestors.each do |ancestor|
        ancestor_origin_id = ancestor.origin_id.presence || ancestor.id

        raise Error, "Invalid creatives" if origin_descendant_ids.include?(ancestor_origin_id)
      end
    end

    def insert_link_shell!(origin, target, new_parent, direction)
      Creative.transaction do
        new_creative = Creative.create!(
          origin_id: origin.id,
          parent: new_parent,
          user: new_parent&.user || user
        )

        siblings = sibling_scope(new_parent).reject { |s| s.id == new_creative.id }
        resequence!(place_relative_to(siblings, new_creative, target, direction))

        new_creative
      end
    end

    # Returns `siblings` with `creative` placed relative to `target`: appended
    # for "child", before or after the target for "up"/"down".
    def place_relative_to(siblings, creative, target, direction)
      return siblings << creative if direction == "child"

      target_index = siblings.index { |s| s.id == target.id } || 0
      insert_index = direction == "up" ? target_index : target_index + 1
      siblings.insert([ [ insert_index, 0 ].max, siblings.size ].min, creative)
    end

    def reorder_as_child(dragged, target)
      dragged.update!(parent: target)
      siblings = target.children.order(:sequence).to_a
      siblings.reject! { |s| s.id == dragged.id }
      siblings << dragged
      resequence!(siblings)
    end

    def reorder_as_sibling(dragged, target, direction)
      if dragged.parent_id != target.parent_id
        dragged.update!(parent: target.parent)
      end

      siblings = sibling_scope(dragged.parent)
      siblings.reject! { |s| s.id == dragged.id }
      target_index = siblings.index { |s| s.id == target.id }
      new_index = direction == "up" ? target_index : target_index.to_i + 1
      siblings.insert(new_index, dragged)
      resequence!(siblings)
    end

    def reorder_multiple_as_child(dragged_creatives, target)
      Creative.transaction do
        siblings = target.children.order(:sequence).to_a
        dragged_ids = dragged_creatives.map(&:id)
        siblings.reject! { |s| dragged_ids.include?(s.id) }

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
        dragged_ids = dragged_creatives.map(&:id)
        siblings.reject! { |s| dragged_ids.include?(s.id) }

        dragged_creatives.each do |dragged|
          dragged.update!(parent: parent)
        end

        target_index = siblings.index { |s| s.id == target.id }
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
      return if creatives.empty?

      table = Creative.arel_table
      cases = Arel::Nodes::Case.new(table[Creative.primary_key])
      creatives.each_with_index do |creative, index|
        cases.when(creative.id).then(index)
      end

      relation = Creative.where(id: creatives.map(&:id))
      Creatives::History.record_bulk(relation, operation: "reorder") do
        relation.update_all(sequence: cases)
      end

      creatives.each_with_index do |creative, index|
        creative.write_attribute(:sequence, index)
        creative.send(:clear_attribute_change, :sequence)
      end
    end
  end
end
end
