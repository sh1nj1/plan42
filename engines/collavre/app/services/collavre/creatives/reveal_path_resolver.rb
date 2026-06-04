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
  # Returns { hit_id (Integer) => { origin_ancestor_id (Integer) => [user_tree_id, ...] } },
  # i.e. for each hit, a per-origin-ancestor map: every origin ancestor (incl.
  # the hit itself) that the user holds a renderable shell for maps to the local
  # path that surfaces *that* shell. The client anchors a breadcrumb click at the
  # entry at/above the clicked crumb, so a higher ancestor crumb resolves through
  # its own shell rather than a deeper one (a user may hold shells at several
  # depths of the same shared subtree). Hits not routed through any shell are
  # omitted (their origin path already matches rendered ids).
  class RevealPathResolver
    def initialize(creative_ids, user: nil, include_archived: false)
      @ids = Array(creative_ids).map { |id| id.to_s.to_i }.uniq.reject(&:zero?)
      @user = user
      @include_archived = include_archived
    end

    def call
      return {} if @ids.empty? || user.nil?

      # Origin-space self+ancestor rows for every hit (generations 0 = self).
      hit_rows = CreativeHierarchy
        .where(descendant_id: @ids)
        .pluck(:descendant_id, :ancestor_id, :generations)
      return {} if hit_rows.empty?

      shells_by_origin = user_shells_by_origin(hit_rows.map { |_d, a, _g| a }.uniq)
      return {} if shells_by_origin.empty?

      local_prefix = local_ancestor_paths(shells_by_origin.values.flatten.uniq)

      # For each hit, map every origin ancestor (incl. self) that has a renderable
      # user shell to the local path [localFolder..., shellId] surfacing it.
      hit_rows.group_by { |descendant_id, _a, _g| descendant_id }
        .each_with_object({}) do |(hit_id, rows), out|
          paths = rows.each_with_object({}) do |(_d, ancestor_id, _g), acc|
            next if acc.key?(ancestor_id)

            shell_ids = shells_by_origin[ancestor_id]
            next unless shell_ids

            # A user may hold several shells for the same origin; pick the first
            # whose local path is actually renderable (not behind an archived
            # folder; [] for a root shell counts as renderable).
            shell_id = shell_ids.find { |sid| local_prefix[sid] }
            next unless shell_id

            acc[ancestor_id] = local_prefix[shell_id] + [ shell_id ]
          end
          out[hit_id] = paths if paths.any?
        end
    end

    private

    attr_reader :ids, :user, :include_archived

    # Shells the signed-in user owns whose origin is one of the hits' ancestors,
    # grouped by origin id (a user can hold more than one shell per origin).
    # Archived shells are excluded (unless show_archived) so the reveal path only
    # targets nodes the browse endpoint actually renders.
    def user_shells_by_origin(origin_ids)
      return {} if origin_ids.empty?

      scope = Creative
        .where(user_id: user.id)
        .where.not(origin_id: nil)
        .where(origin_id: origin_ids)
      scope = scope.where(archived_at: nil) unless include_archived
      scope.pluck(:origin_id, :id).each_with_object({}) do |(origin_id, id), grouped|
        (grouped[origin_id] ||= []) << id
      end
    end

    # User-local ancestors of each shell (the user's own folders above it),
    # ordered root-most down to the shell's immediate parent. Returns nil for a
    # shell whose path crosses an archived (unrendered) folder, since the browse
    # path could never expand down to it.
    def local_ancestor_paths(shell_ids)
      rows = CreativeHierarchy
        .where(descendant_id: shell_ids)
        .where("generations > 0")
        .pluck(:descendant_id, :ancestor_id, :generations)
      by_shell = rows.group_by { |descendant_id, _a, _g| descendant_id }
      archived = archived_ancestor_ids(rows.map { |_d, a, _g| a }.uniq)

      shell_ids.index_with do |shell_id|
        ordered = (by_shell[shell_id] || [])
          .sort_by { |_d, _a, generations| -generations }
          .map { |_d, ancestor_id, _g| ancestor_id }
        ordered.any? { |ancestor_id| archived.include?(ancestor_id) } ? nil : ordered
      end
    end

    # Ancestor folder ids that are archived (and thus hidden from the browse path
    # unless show_archived). Empty when show_archived is set.
    def archived_ancestor_ids(ancestor_ids)
      return Set.new if include_archived || ancestor_ids.empty?

      Creative.where(id: ancestor_ids).where.not(archived_at: nil).pluck(:id).to_set
    end
  end
end
end
