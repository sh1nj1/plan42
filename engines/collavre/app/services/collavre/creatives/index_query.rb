module Collavre
module Creatives
  class IndexQuery
    # Cap flat search results for the lightweight picker popup (simple mode).
    # The full-page search (no `simple` flag) is intentionally unbounded.
    SIMPLE_SEARCH_LIMIT = 50

    # Permission-check matched rows in rank order in slices of this size, so a
    # heavily-matched query only checks the prefix needed to fill the cap rather
    # than its entire match set.
    PERMISSION_FILTER_BATCH = 200

    # Page size for the top-nav "Chats" feed (the comment filter). The list is
    # unbounded by nature (it grows with every commented creative), so it is
    # paginated instead of materialized whole.
    COMMENT_CHATS_PER_PAGE = 30

    Result = Struct.new(
      :creatives,
      :parent_creative,
      :shared_creative,
      :shared_list,
      :overall_progress,
      :allowed_creative_ids,
      :progress_map,
      :pagination,
      keyword_init: true
    )

    def initialize(user:, params: {})
      @user = user
      @params = params.with_indifferent_access
    end

    def call
      result = resolve_creatives
      shared_creative = result[:parent] || result[:creatives]&.first
      shared_list = shared_creative ? shared_creative.all_shared_users : []

      Result.new(
        creatives: result[:creatives],
        parent_creative: result[:parent],
        shared_creative: shared_creative,
        shared_list: shared_list,
        overall_progress: result[:overall_progress] || 0,
        allowed_creative_ids: result[:allowed_ids],
        progress_map: result[:progress_map],
        pagination: result[:pagination]
      )
    end

    private

    attr_reader :user, :params

    def resolve_creatives
      if any_filter_active?
        handle_filtered_query
      elsif params[:id]
        handle_id_query
      else
        handle_root_query
      end
    end

    def any_filter_active?
      # ROUTING_KEYS excludes show_archived: archived visibility is handled by
      # the base scope, not by routing through FilterPipeline.
      FilterParams.active?(params, FilterParams::ROUTING_KEYS)
    end

    def handle_filtered_query
      scope = determine_scope
      pipeline = FilterPipeline.new(user: user, params: params, scope: scope)

      # The picker's flat search (simple mode) only renders matched rows ranked
      # and capped; ancestors, progress_map and overall_progress are full-page
      # concerns it never reads (breadcrumbs are resolved separately). Skip that
      # work — and the per-row readable? N+1 — so a 2-char query in a large tree
      # caps before doing unbounded resolution.
      return simple_search_result(pipeline) if simple_search?

      result = pipeline.call

      # The comment ("Chats") path still returns a pagination object on an empty
      # match so the client gets consistent metadata; other filters short-circuit.
      return empty_result if result.matched_ids.empty? && params[:comment] != "true"

      # For search/comment filters, return matched items directly (flat results sorted by relevance)
      # Unless search_mode=tree is specified, which returns tree structure instead
      # For other filters (tags, progress), return tree start nodes
      if (params[:search].present? || params[:comment] == "true") && params[:search_mode] != "tree"
        parent = params[:id] ? Creative.find_by(id: params[:id]) : nil

        if params[:comment] == "true"
          # Top-nav "Chats" list: one page of commented creatives, newest chat
          # first. The matched set is permission-filtered in a single batch and
          # the recency ordering is computed by the DB (LIMIT/OFFSET over a
          # grouped MAX(comments.updated_at)), so response cost is a fixed page
          # regardless of how many chats exist. This replaces an unbounded load
          # that ran a per-row readable? query and a per-row MAX(updated_at)
          # aggregate (two N+1s that grew with the chat count).
          page = comment_chats_page(result.matched_ids)
          {
            creatives: page[:creatives],
            parent: parent,
            allowed_ids: result.allowed_ids,
            overall_progress: result.overall_progress,
            progress_map: result.progress_map,
            pagination: page[:pagination]
          }
        else
          matched_creatives = Creative.where(id: result.matched_ids.to_a)
            .order(:sequence)
            .select { |c| readable?(c) }

          {
            creatives: matched_creatives,
            parent: parent,
            allowed_ids: result.allowed_ids,
            overall_progress: result.overall_progress,
            progress_map: result.progress_map
          }
        end
      else
        start_nodes = determine_start_nodes(result.allowed_ids)
        parent = params[:id] ? Creative.find_by(id: params[:id]) : nil
        {
          creatives: start_nodes,
          parent: parent,
          allowed_ids: result.allowed_ids,
          overall_progress: result.overall_progress,
          progress_map: result.progress_map
        }
      end
    end

    # One page of the "Chats" feed from the comment-matched id set, ordered by
    # most-recent comment. Permission filtering is batched (PermissionFilter does
    # a handful of IN queries, not one per row) and the recency sort + windowing
    # happen in SQL, so neither cost scales with the total number of chats.
    def comment_chats_page(matched_ids)
      per_page = comment_chats_per_page
      page = comment_chats_page_number
      offset = (page - 1) * per_page

      readable_ids = PermissionFilter.new(user: user).readable_ids(matched_ids.to_a)
      return { creatives: [], pagination: pagination_meta(page, false) } if readable_ids.empty?

      # Fetch one extra row to detect whether a further page exists. id is the
      # tiebreaker so the order is total and stable across page boundaries.
      page_ids = Creative.where(id: readable_ids)
        .joins(:comments)
        .group("creatives.id")
        .order(Arel.sql("MAX(comments.updated_at) DESC, creatives.id DESC"))
        .offset(offset)
        .limit(per_page + 1)
        .pluck("creatives.id")

      has_more = page_ids.size > per_page
      page_ids = page_ids.first(per_page)

      by_id = Creative.where(id: page_ids).index_by(&:id)
      creatives = page_ids.filter_map { |id| by_id[id] }

      { creatives: creatives, pagination: pagination_meta(page, has_more) }
    end

    def comment_chats_per_page
      per = params[:per_page].presence&.to_i || COMMENT_CHATS_PER_PAGE
      per <= 0 || per > 100 ? COMMENT_CHATS_PER_PAGE : per
    end

    def comment_chats_page_number
      page = params[:page].presence&.to_i || 1
      page < 1 ? 1 : page
    end

    def pagination_meta(page, has_more)
      { page: page, next_page: has_more ? page + 1 : nil, has_more: has_more }
    end

    def simple_search?
      params[:search].present? && params[:simple].present? &&
        params[:search_mode] != "tree" && params[:comment] != "true"
    end

    # Lightweight flat-search path for the picker popup: matched rows only,
    # permission-filtered in one batch, ranked by relevance and capped — without
    # resolving ancestors/progress for the whole match set.
    def simple_search_result(pipeline)
      relation = pipeline.search_only_relation
      ids = if relation
        windowed_readable_ids(relation)
      else
        matched = pipeline.matched_ids
        matched.empty? ? [] : ranked_readable_window(matched)
      end
      return empty_result if ids.empty?

      by_id = Creative.where(id: ids).index_by(&:id)
      creatives = ids.filter_map { |id| by_id[id] }

      {
        creatives: creatives,
        parent: params[:id] ? Creative.find_by(id: params[:id]) : nil,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    # Window the ranked search matches entirely in SQL: order by relevance and
    # pull PERMISSION_FILTER_BATCH-sized slices via LIMIT/OFFSET, permission-filtering
    # each and stopping as soon as the cap is filled. The match itself stays a
    # subquery (`id IN (<search relation>)`), so Ruby never holds the full match-id
    # set at once — only one PERMISSION_FILTER_BATCH window is in memory at a time.
    # Wrapping the join+distinct search as a subquery also keeps the outer relation
    # join-free, so `ORDER BY LENGTH(description)` is portable (no Postgres
    # "DISTINCT + ORDER BY must be in select list" issue). The DB still scans/sorts
    # all matches (inherent to a leading-wildcard LIKE + global relevance ranking),
    # but the rows crossing into Ruby are bounded per window.
    #
    # The loop continues until the cap is filled OR the match set is exhausted —
    # there is no fixed window ceiling. A ceiling would silently truncate results:
    # in a multi-user install the match scope is every `origin_id: nil` row before
    # permission filtering, so a user's readable matches can sort after many
    # unreadable ones, and capping the scan would return an empty/incomplete result
    # even though matching readable creatives exist. Termination is guaranteed by the
    # finite match set (offset advances past the last row → empty window → break);
    # per-window memory stays bounded regardless of how deep the scan goes.
    # PermissionFilter stays the single source of read permission. LENGTH() is
    # portable across SQLite/Postgres/MySQL and byte-vs-char length is immaterial
    # for a ranking heuristic.
    def windowed_readable_ids(relation)
      ordered = Creative.where(id: relation.select(:id))
        .order(Arel.sql("LENGTH(creatives.description)"), :id)

      readable = []
      offset = 0
      loop do
        window = ordered.offset(offset).limit(PERMISSION_FILTER_BATCH).pluck(:id)
        break if window.empty?

        permitted = PermissionFilter.new(user: user).readable_ids(window).to_set
        window.each { |id| readable << id if permitted.include?(id) }
        break if readable.size >= SIMPLE_SEARCH_LIMIT || window.size < PERMISSION_FILTER_BATCH

        offset += PERMISSION_FILTER_BATCH
      end
      readable.first(SIMPLE_SEARCH_LIMIT)
    end

    # Fallback for when other filters are active alongside search (no single-relation
    # form): rank the already-matched ids by relevance in the DB, then permission-filter
    # in that order one slice at a time, stopping as soon as the cap is filled. Only the
    # prefix needed for SIMPLE_SEARCH_LIMIT readable rows is permission-checked and
    # materialized. The matched-id set itself is plucked up front here (it was already
    # intersected across filters in Ruby), which is why the search-only path prefers the
    # windowed subquery above. PermissionFilter stays the single source of read permission.
    def ranked_readable_window(matched)
      ranked_ids = Creative.where(id: matched)
        .order(Arel.sql("LENGTH(creatives.description)"), :id)
        .pluck(:id)

      readable = []
      ranked_ids.each_slice(PERMISSION_FILTER_BATCH) do |slice|
        permitted = PermissionFilter.new(user: user).readable_ids(slice).to_set
        slice.each { |id| readable << id if permitted.include?(id) }
        break if readable.size >= SIMPLE_SEARCH_LIMIT
      end
      readable.first(SIMPLE_SEARCH_LIMIT)
    end

    def handle_id_query
      creative = Creative.find_by(id: params[:id])
      return empty_result unless creative && readable?(creative)

      children = creative.children_with_permission(user, :read)
      children = children.select { |c| !c.archived? } unless params[:show_archived]

      {
        creatives: children,
        parent: creative,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    def handle_root_query
      roots = Creative.where(user: user).roots
      roots = roots.where(archived_at: nil) unless params[:show_archived]

      {
        creatives: roots,
        parent: nil,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    def determine_scope
      base_scope = if params[:id]
        base = Creative.find_by(id: params[:id])&.effective_origin
        return Creative.none unless base

        # Use subqueries instead of loading IDs into memory
        # 1. Actual descendants (via creative_hierarchies)
        descendants_subquery = CreativeHierarchy
          .where(ancestor_id: base.id)
          .select(:descendant_id)

        # 2. Linked descendants: origins of shell creatives -> their descendants
        # First, find shell creatives in the subtree
        shells_in_subtree = Creative
          .where("creatives.id IN (?)", descendants_subquery)
          .where.not(origin_id: nil)
          .select(:origin_id)

        # Then, get descendants of those origins
        linked_descendants_subquery = CreativeHierarchy
          .where("ancestor_id IN (?)", shells_in_subtree)
          .select(:descendant_id)

        # Combine both subqueries (use creatives.id to avoid ambiguity with joins)
        Creative.where(
          "creatives.id IN (?) OR creatives.id IN (?)",
          descendants_subquery,
          linked_descendants_subquery
        )
      else
        Creative.where(origin_id: nil)  # Only real creatives (not shells)
      end

      # Exclude archived creatives from all filters/search unless explicitly requested
      base_scope = base_scope.where(archived_at: nil) unless params[:show_archived]
      base_scope
    end

    def determine_start_nodes(allowed_ids)
      allowed_ids_array = allowed_ids.map { |id| id.to_s.to_i }
      allowed_ids_set = allowed_ids.to_set

      if params[:id]
        parent = Creative.find_by(id: params[:id])
        return [] unless parent && readable?(parent)

        parent.children.where(id: allowed_ids_array).order(:sequence).to_a
      else
        # Root view: only show creatives with parent_id = nil
        # This prevents Linked Creatives (which have parent_id) from appearing at root
        # even if their ancestors are not in allowed_ids
        Creative.where(id: allowed_ids_array, parent_id: nil).order(:sequence).to_a
      end
    end

    def readable?(creative)
      creative.user == user || creative.has_permission?(user, :read)
    end

    def empty_result
      { creatives: [], parent: nil, allowed_ids: Set.new, overall_progress: 0, progress_map: {} }
    end
  end
end
end
