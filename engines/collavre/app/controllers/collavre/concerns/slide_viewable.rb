module Collavre
  module Concerns
    module SlideViewable
      extend ActiveSupport::Concern

      def slide_view
        unless @creative.has_permission?(Current.user, :read)
          if Current.user
            redirect_to creatives_path, alert: t("collavre.creatives.errors.no_permission")
          else
            request_authentication
          end
          return
        end

        @slide_ids = []
        @root_depth = @creative.ancestors.count
        build_slide_ids(@creative)
        render layout: "collavre/slide"
      end

      private

      # Builds @slide_ids by performing an in-order DFS traversal of the
      # creative tree rooted at +root+, including any "linked children"
      # (children of the node's origin when the node is a linked creative).
      #
      # Performance: a naive recursion issues one query per node for both
      # +children+ and +linked_children+ (O(N) queries for an N-node tree).
      # This implementation walks the tree level-by-level via batched queries,
      # so total DB round-trips scale with tree depth rather than node count.
      def build_slide_ids(root)
        user = Current.user
        return unless root.has_permission?(user, :read)

        children_by_parent = {}
        permission_cache = { root.id => true }

        # BFS over the creative tree, batching DB lookups one level at a time.
        # Only nodes the user may read are expanded, matching the original
        # recursion which short-circuits on permission denial.
        frontier = [ root ]
        until frontier.empty?
          # 1) Load own children for every node in the current level in one query.
          parent_ids = frontier.map(&:id)
          own_children_by_parent = Creative
            .where(parent_id: parent_ids)
            .order(:sequence)
            .group_by(&:parent_id)

          # 2) For nodes with an origin, load linked children (origin's children
          #    visible to the user) in a single batched query.
          linked_nodes = frontier.select { |n| n.origin_id.present? }
          linked_children_by_node = preload_linked_children(linked_nodes, user)

          next_frontier = []
          frontier.each do |node|
            own = own_children_by_parent[node.id] || []
            merged = if node.origin_id.present?
              linked = linked_children_by_node[node.id] || []
              (own + linked).uniq.sort_by(&:sequence)
            else
              own
            end
            children_by_parent[node.id] = merged
            next_frontier.concat(merged)
          end

          # 3) Bulk permission check for the next level (uniqued by id).
          next_unique = next_frontier.uniq(&:id)
          uncached = next_unique.reject { |c| permission_cache.key?(c.id) }
          uncached.each do |child|
            permission_cache[child.id] = child.has_permission?(user, :read)
          end

          # Only descend into permitted nodes — matches the recursive version's
          # short-circuit. Iterating in node order keeps duplicates collapsed
          # while preserving discovery order.
          frontier = next_unique.select { |c| permission_cache[c.id] }
        end

        # 4) DFS in memory using the prebuilt maps to populate @slide_ids in
        #    the same order the recursive version would have produced.
        stack = [ root ]
        until stack.empty?
          node = stack.pop
          next unless permission_cache[node.id]

          @slide_ids << node.id
          children = children_by_parent[node.id] || []
          # Push in reverse so DFS visits in ascending sequence order.
          children.reverse_each { |child| stack.push(child) }
        end
      end

      # Returns a hash of +node.id => Array(linked_children)+ for the given
      # nodes (each of which must have +origin_id+ present). Equivalent in
      # result to calling +node.linked_children+ on each node, but executes a
      # bounded number of queries regardless of how many nodes are passed in.
      def preload_linked_children(nodes, user)
        return {} if nodes.empty?

        # Resolve each node's effective origin (follows linked chains).
        # effective_origin walks the chain by reading the origin association;
        # repeated calls within a request hit ActiveRecord's identity per
        # instance, so this is bounded by the linked-chain depth.
        origin_for_node = {}
        nodes.each do |node|
          origin = node.effective_origin(Set.new)
          origin_for_node[node.id] = origin if origin
        end

        unique_origin_ids = origin_for_node.values.map(&:id).uniq
        return {} if unique_origin_ids.empty?

        # Single batched query for all candidate children across all origins.
        candidate_children = Creative
          .where(parent_id: unique_origin_ids)
          .order(:sequence)
          .to_a
        candidates_by_origin = candidate_children.group_by(&:parent_id)
        candidate_ids = candidate_children.map(&:id)

        accessible_ids = accessible_child_ids(candidate_ids, candidate_children, user)

        result = {}
        nodes.each do |node|
          origin = origin_for_node[node.id]
          next unless origin

          children = candidates_by_origin[origin.id] || []
          result[node.id] = children.select { |c| accessible_ids.include?(c.id) }
        end
        result
      end

      # Mirrors the access check in Creative#children_with_permission, but
      # operates on a pre-fetched set of candidate children so the work
      # collapses to a fixed number of queries instead of one per parent.
      def accessible_child_ids(candidate_ids, candidate_children, user)
        return Set.new if candidate_ids.empty?

        min_rank = CreativeShare.permissions["read"]
        accessible = Set.new

        if user
          user_entries = CreativeSharesCache
            .where(creative_id: candidate_ids, user_id: user.id)
            .pluck(:creative_id, :permission)

          user_has_entry = Set.new
          user_entries.each do |cid, perm|
            user_has_entry << cid
            perm_rank = CreativeSharesCache.permissions[perm]
            if perm_rank && perm_rank >= min_rank && perm_rank != CreativeSharesCache.permissions[:no_access]
              accessible << cid
            end
          end

          public_accessible = CreativeSharesCache
            .where(creative_id: candidate_ids, user_id: nil)
            .where("permission >= ?", min_rank)
            .where.not(permission: :no_access)
            .pluck(:creative_id)
          accessible.merge(public_accessible.reject { |cid| user_has_entry.include?(cid) })

          owned_ids = candidate_children.select { |c| c.user_id == user.id }.map(&:id)
          accessible.merge(owned_ids)
        else
          public_accessible = CreativeSharesCache
            .where(creative_id: candidate_ids, user_id: nil)
            .where("permission >= ?", min_rank)
            .where.not(permission: :no_access)
            .pluck(:creative_id)
          accessible.merge(public_accessible)
        end

        accessible
      end
    end
  end
end
