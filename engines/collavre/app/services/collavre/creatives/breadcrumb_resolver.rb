module Collavre
module Creatives
  # Resolves the ancestor path (breadcrumb) for a set of creatives in a small,
  # fixed number of queries — used to annotate flat search results in the
  # creative picker popup with "where it lives" context.
  #
  # Returns a hash: { creative_id (Integer) => [{ id:, description:, restricted: }, ...] }
  # where the array is ordered from root-most ancestor down to the immediate
  # parent (self is excluded). Ancestors the user cannot read are kept in the
  # path (so depth is preserved) but their text is masked with `restricted: true`
  # and a nil description, mirroring how the full-page tree drops inaccessible
  # ancestors after permission filtering.
  class BreadcrumbResolver
    def initialize(creative_ids, user: nil)
      @ids = Array(creative_ids).map { |id| id.to_s.to_i }.uniq.reject(&:zero?)
      @user = user
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
      ancestor_labels = build_ancestor_labels(accessible)

      grouped = Hash.new { |h, k| h[k] = [] }
      rows.each { |descendant_id, ancestor_id, generations| grouped[descendant_id] << [ generations, ancestor_id ] }

      grouped.transform_values do |pairs|
        # Larger generation distance = closer to the root, so order descending.
        pairs.sort_by { |generations, _ancestor_id| -generations }.map do |_generations, ancestor_id|
          if accessible.include?(ancestor_id)
            { id: ancestor_id, description: ancestor_labels[ancestor_id] }
          else
            { id: ancestor_id, description: nil, restricted: true }
          end
        end
      end
    end

    private

    attr_reader :ids, :user

    # Batched read-permission filter for the ancestor set, mirroring the
    # CreativeSharesCache lookup used by Creative#children_with_permission so a
    # node shared without its parents never leaks the parent's text.
    def accessible_ancestor_ids(ancestor_ids)
      return Set.new if ancestor_ids.empty?

      no_access = CreativeSharesCache.permissions[:no_access]
      accessible = Set.new

      if user
        denied = Set.new
        user_seen = Set.new
        CreativeSharesCache.where(creative_id: ancestor_ids, user_id: user.id)
          .pluck(:creative_id, :permission).each do |cid, perm|
            user_seen << cid
            CreativeSharesCache.permissions[perm] == no_access ? denied << cid : accessible << cid
          end

        public_ids = CreativeSharesCache.where(creative_id: ancestor_ids, user_id: nil)
          .where.not(permission: :no_access).pluck(:creative_id)
        accessible.merge(public_ids.reject { |cid| user_seen.include?(cid) || denied.include?(cid) })

        owned_ids = Creative.where(id: ancestor_ids, user_id: user.id).pluck(:id)
        accessible.merge(owned_ids)
      else
        accessible = CreativeSharesCache.where(creative_id: ancestor_ids, user_id: nil)
          .where.not(permission: :no_access).pluck(:creative_id).to_set
      end

      accessible
    end

    def build_ancestor_labels(accessible_ids)
      return {} if accessible_ids.empty?

      # Load records (with origin) so Linked Creatives resolve to their origin's
      # text via effective_description. The ancestor set is small (sum of path
      # depths, deduped), so this stays cheap.
      Creative.where(id: accessible_ids.to_a).includes(:origin).to_h do |creative|
        [ creative.id, creative.effective_description(nil, false).to_s.gsub(/\s+/, " ").strip ]
      end
    end
  end
end
end
