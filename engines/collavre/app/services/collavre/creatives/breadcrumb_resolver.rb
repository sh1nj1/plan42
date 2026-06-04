module Collavre
module Creatives
  # Resolves the ancestor path (breadcrumb) for a set of creatives in a small,
  # fixed number of queries — used to annotate flat search results in the
  # creative picker popup with "where it lives" context.
  #
  # Returns a hash: { creative_id (Integer) => [{ id:, description:, restricted: }, ...] }
  # where the array is ordered from root-most ancestor down to the immediate
  # parent (self is excluded). Ancestors the user cannot read — or that are
  # archived while archived rows aren't being shown — are kept in the path (so
  # depth is preserved) but their text is masked with `restricted: true` and a
  # nil description, mirroring how the full-page tree drops inaccessible
  # ancestors after permission filtering. Archived ancestors are masked because
  # the picker browse endpoints hide archived rows unless show_archived, so a
  # jump to such a crumb would expand a node that never renders.
  class BreadcrumbResolver
    def initialize(creative_ids, user: nil, include_archived: false)
      @ids = Array(creative_ids).map { |id| id.to_s.to_i }.uniq.reject(&:zero?)
      @user = user
      @include_archived = include_archived
    end

    def call
      return {} if @ids.empty?

      # One query: every (descendant, ancestor, distance) pair, excluding self.
      rows = CreativeHierarchy
        .where(descendant_id: @ids)
        .where("generations > 0")
        .pluck(:descendant_id, :ancestor_id, :generations)
      return {} if rows.empty?

      ancestor_ids = rows.map { |_d, a, _g| a }.uniq
      accessible = accessible_ancestor_ids(ancestor_ids)
      records = ancestor_records(accessible)
      renderable = renderable_ancestor_ids(accessible, records)

      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each { |descendant_id, ancestor_id, generations| grouped[descendant_id] << [ generations, ancestor_id ] }

      grouped.transform_values do |pairs|
        # Larger generation distance = closer to the root, so order descending.
        pairs.sort_by { |generations, _ancestor_id| -generations }.map do |_generations, ancestor_id|
          if renderable.include?(ancestor_id)
            { id: ancestor_id, description: ancestor_label(records[ancestor_id]) }
          else
            { id: ancestor_id, description: nil, restricted: true }
          end
        end
      end
    end

    private

    attr_reader :ids, :user, :include_archived

    # Batched read-permission filter for the ancestor set so a node shared
    # without its parents never leaks the parent's text. Delegates to the
    # canonical PermissionFilter — the same batch posture the picker's
    # has_children check and FilterPipeline use — rather than re-deriving it.
    def accessible_ancestor_ids(ancestor_ids)
      return Set.new if ancestor_ids.empty?

      PermissionFilter.new(user: user).readable_ids(ancestor_ids).to_set
    end

    # Load readable ancestor records once (with origin so Linked Creatives
    # resolve to their origin's text). Reused for both the archived check and
    # the labels, so query count is unchanged. The ancestor set is small (sum of
    # path depths, deduped), so this stays cheap.
    def ancestor_records(accessible_ids)
      return {} if accessible_ids.empty?

      Creative.where(id: accessible_ids.to_a).includes(:origin).index_by(&:id)
    end

    # A readable ancestor is renderable unless it's archived and archived rows
    # aren't being shown — matching exactly the rows the browse endpoints emit,
    # so a breadcrumb jump never targets a node the tree won't render.
    def renderable_ancestor_ids(accessible_ids, records)
      return accessible_ids if include_archived

      accessible_ids.reject { |id| records[id]&.archived? }.to_set
    end

    def ancestor_label(creative)
      creative.effective_description(nil, false).to_s.gsub(/\s+/, " ").strip
    end
  end
end
end
