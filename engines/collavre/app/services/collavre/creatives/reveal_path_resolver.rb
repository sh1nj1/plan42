module Collavre
module Creatives
  # Resolves, for each flat-search hit that is only reachable through a linked
  # creative shell, the path of node ids to expand *in the signed-in user's own
  # tree* to surface that shell — ordered root-most ancestor down to the shell
  # itself.
  #
  # Why this exists: search breadcrumbs (BreadcrumbResolver) carry the hit's
  # *origin-space* ancestors. When a shared subtree is represented by a shell
  # nested under one of the user's own folders, those origin ancestors never
  # include the local folder that contains the shell, so the picker's
  # breadcrumb-jump cannot expand down to it (the shell <li> is never rendered
  # and `_findItem` returns null). This service supplies the missing user-local
  # prefix `[localFolder..., shellId]`; the client expands it before walking the
  # origin chain. Display is unaffected — only navigation.
  #
  # Returns { hit_id (Integer) => [user_tree_id, ...] }, omitting hits that are
  # not routed through a shell (their origin path already matches rendered ids).
  class RevealPathResolver
    def initialize(creative_ids, user: nil)
      @ids = Array(creative_ids).map { |id| id.to_s.to_i }.uniq.reject(&:zero?)
      @user = user
    end

    def call
      return {} if @ids.empty? || user.nil?

      # Origin-space self+ancestor rows for every hit (generations 0 = self).
      hit_rows = CreativeHierarchy
        .where(descendant_id: @ids)
        .pluck(:descendant_id, :ancestor_id, :generations)
      return {} if hit_rows.empty?

      shell_by_origin = user_shells_by_origin(hit_rows.map { |_d, a, _g| a }.uniq)
      return {} if shell_by_origin.empty?

      shell_for_hit = resolve_shell_for_hit(hit_rows, shell_by_origin)
      return {} if shell_for_hit.empty?

      local_prefix = local_ancestor_paths(shell_for_hit.values.uniq)

      shell_for_hit.transform_values { |shell_id| local_prefix[shell_id] + [ shell_id ] }
    end

    private

    attr_reader :ids, :user

    # Shells the signed-in user owns whose origin is one of the hits' ancestors,
    # keyed by origin id.
    def user_shells_by_origin(origin_ids)
      return {} if origin_ids.empty?

      Creative
        .where(user_id: user.id)
        .where.not(origin_id: nil)
        .where(origin_id: origin_ids)
        .pluck(:origin_id, :id)
        .to_h
    end

    # For each hit, pick the deepest (closest) ancestor-or-self that the user has
    # a shell for — that shell is the entry point rendering the hit's subtree.
    def resolve_shell_for_hit(hit_rows, shell_by_origin)
      result = {}
      hit_rows.group_by { |descendant_id, _a, _g| descendant_id }.each do |hit_id, rows|
        best = rows.select { |_d, ancestor_id, _g| shell_by_origin.key?(ancestor_id) }
          .min_by { |_d, _a, generations| generations }
        result[hit_id] = shell_by_origin[best[1]] if best
      end
      result
    end

    # User-local ancestors of each shell (the user's own folders above it),
    # ordered root-most down to the shell's immediate parent.
    def local_ancestor_paths(shell_ids)
      paths = Hash.new { |h, k| h[k] = [] }
      rows = CreativeHierarchy
        .where(descendant_id: shell_ids)
        .where("generations > 0")
        .pluck(:descendant_id, :ancestor_id, :generations)
      rows.group_by { |descendant_id, _a, _g| descendant_id }.each do |shell_id, srows|
        paths[shell_id] = srows.sort_by { |_d, _a, generations| -generations }.map { |_d, ancestor_id, _g| ancestor_id }
      end
      paths
    end
  end
end
end
