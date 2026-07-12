module Collavre
module Creatives
  # Serializes a flat collection of creatives into the lightweight JSON payload
  # consumed by the picker popup (simple mode) and the plain browse list.
  #
  # Extracted from CreativesController#index so the controller action stays thin.
  # Depends only on the acting user and the request params (read-only), never on
  # view_context, so the whole responsibility lives outside the controller.
  class CreativeTreeSerializer
    def initialize(user:, params:)
      @user = user
      @params = params
    end

    def serialize(collection)
      if params[:simple].present?
        serialize_simple(collection)
      else
        collection.map { |c| { id: c.id, description: c.effective_description, progress: c.progress } }
      end
    end

    private

    attr_reader :user, :params

    def serialize_simple(collection)
      # Preload origins so effective_origin (used per linked-shell row in both
      # children_presence_set and the origin_id mapping below) resolves from
      # memory instead of firing a query per shell. Only browse can hold shells;
      # search is scoped to origin_id: nil, so this is a no-op there.
      ActiveRecord::Associations::Preloader.new(records: collection.to_a, associations: :origin).call
      children_ids = children_presence_set(collection)
      searching = params[:search].present?
      breadcrumbs = searching ? BreadcrumbResolver.new(collection.map(&:id), user: user, include_archived: params[:show_archived].present?).call : {}
      # For hits routed through a linked shell, the path to expand in the
      # user's own tree (local folders -> shell) so a breadcrumb jump can
      # reach a shell nested under a collapsed folder.
      reveal_paths = searching ? RevealPathResolver.new(collection.map(&:id), user: user, include_archived: params[:show_archived].present?).call : {}
      collection.map do |c|
        item = {
          id: c.id,
          description: c.effective_description(nil, false),
          progress: c.progress,
          has_children: children_ids.include?(c.id)
        }
        reveal = reveal_paths[c.id]
        path = breadcrumbs[c.id]
        if path.present?
          item[:path] = mask_unreachable_crumbs(path, reveal)
        end
        item[:reveal_path] = reveal if reveal.present?
        # For linked shells, expose the effective origin id so the picker can
        # map a search breadcrumb (origin ids) back to the rendered shell node.
        item[:origin_id] = c.effective_origin.id if c.origin_id
        item
      end
    end

    # A breadcrumb jump expands the tree from a rendered root (or, for a shared
    # subtree, a linked shell) down to the clicked crumb. If an ancestor above a
    # crumb is itself unrenderable (unreadable, or archived while archived rows
    # aren't shown) and no linked shell re-roots the path at/below it, the
    # descendant can't be expanded either — so mask it too. BreadcrumbResolver
    # masks the unrenderable ancestor itself; this masks everything downstream of
    # it on the plain origin chain, matching exactly what the tree can render.
    #
    # `reveal` is RevealPathResolver's per-origin map: a crumb whose origin id is
    # a key re-roots navigation through its own shell (the client anchors at the
    # nearest reveal entry at/above the clicked crumb), so it clears the block for
    # itself and its descendants regardless of an archived/unreadable origin
    # above it.
    def mask_unreachable_crumbs(path, reveal)
      blocked = false
      path.map do |crumb|
        if reveal&.key?(crumb[:id])
          blocked = false
          crumb
        elsif crumb[:restricted]
          blocked = true
          crumb
        elsif blocked
          crumb.merge(restricted: true, description: nil)
        else
          crumb
        end
      end
    end

    # Batched "does this node have a child the user can actually browse to?"
    # lookup so the picker tree renders expand toggles without an N+1.
    #
    # Must match exactly what expanding the node shows (IndexQuery#handle_id_query
    # -> children_with_permission, minus archived unless show_archived), or the
    # toggle either hides a reachable subtree or opens to an empty branch (and
    # leaks that hidden children exist). Two alignments are needed:
    #   1. Linked shells (origin_id set) store children under the effective
    #      origin (redirect_parent_to_origin + children->origin migration), so
    #      resolve each row to its effective origin before the lookup.
    #   2. Apply the same archived + read-permission filters as the browse path.
    def children_presence_set(collection)
      return Set.new if collection.empty?

      origin_id_by_id = collection.to_h { |c| [ c.id, c.effective_origin.id ] }

      candidates = Creative.where(parent_id: origin_id_by_id.values.uniq)
      candidates = candidates.where(archived_at: nil) unless params[:show_archived]
      child_rows = candidates.pluck(:id, :parent_id) # [child_id, origin_id]
      return Set.new if child_rows.empty?

      readable = PermissionFilter
        .new(user: user).readable_ids(child_rows.map(&:first)).to_set
      origins_with_visible_children = child_rows
        .each_with_object(Set.new) { |(child_id, origin_id), set| set << origin_id if readable.include?(child_id) }

      collection.each_with_object(Set.new) do |c, set|
        set << c.id if origins_with_visible_children.include?(origin_id_by_id[c.id])
      end
    end
  end
end
end
