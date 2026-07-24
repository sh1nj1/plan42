module Collavre
module Creatives
  # Per-level batch answer to "which children does this node show?" for the
  # browse tree, replacing a per-node `children_with_permission` call.
  #
  # Presence (`has_children?`) is resolved for every node in a level with one
  # plucked scan plus one batched PermissionFilter; the full child rows are
  # materialized only for the nodes that actually render them (expanded, or a
  # filter forcing the subtree open). Presence and content are derived from the
  # same candidate set, so an expand toggle can never open an empty branch or
  # hide a reachable subtree — a drift that would also leak the existence of
  # children the user cannot see.
  #
  # Children of a linked shell live under its effective origin, so every lookup
  # resolves the shell to its origin first. Preload `:origin` on the level before
  # indexing it, or that resolution costs a query per shell.
  class ChildrenIndex
    def initialize(user:, show_archived:, allowed_creative_ids: nil)
      @user = user
      @show_archived = show_archived
      @allowed_creative_ids = allowed_creative_ids
      @child_ids_by_creative = {}
      @rows_by_child_id = {}
    end

    # Scans a level. Only creatives not seen before cost anything, so the
    # recursive descent pays two queries per level, not per node.
    def index(creatives)
      pending = creatives.reject { |c| @child_ids_by_creative.key?(c.id) }
      return if pending.empty?

      origin_id_by_id = pending.to_h { |c| [ c.id, c.effective_origin.id ] }

      candidates = Creative.where(parent_id: origin_id_by_id.values.uniq)
      candidates = candidates.where(archived_at: nil) unless show_archived
      rows = candidates.order(:sequence).pluck(:id, :parent_id)

      visible_by_origin = visible_child_ids_by_origin(rows)
      pending.each do |creative|
        @child_ids_by_creative[creative.id] = visible_by_origin[origin_id_by_id[creative.id]] || []
      end
    end

    def has_children?(creative)
      child_ids(creative).any?
    end

    # Materializes the child rows of `creatives` in a single query. Called only
    # for the nodes whose children actually render.
    def load(creatives)
      wanted = creatives.flat_map { |c| child_ids(c) }.uniq - @rows_by_child_id.keys
      return if wanted.empty?

      Creative.where(id: wanted).each { |child| @rows_by_child_id[child.id] = child }
    end

    # Sequence-ordered, permission- and archive-filtered children. Empty unless
    # `load` has materialized them.
    def children_for(creative)
      child_ids(creative).filter_map { |id| @rows_by_child_id[id] }
    end

    private

    attr_reader :user, :show_archived, :allowed_creative_ids

    # `rows` arrive in sequence order, so the per-origin lists inherit it.
    def visible_child_ids_by_origin(rows)
      return {} if rows.empty?

      readable = PermissionFilter.new(user: user).readable_ids(rows.map(&:first)).to_set

      rows.each_with_object({}) do |(child_id, origin_id), acc|
        next unless readable.include?(child_id)
        next if allowed_creative_ids && !allowed_creative_ids.include?(child_id.to_s)

        (acc[origin_id] ||= []) << child_id
      end
    end

    def child_ids(creative)
      @child_ids_by_creative.fetch(creative.id, [])
    end
  end
end
end
