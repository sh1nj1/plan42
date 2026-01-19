module Creatives
  class IndexQuery
    Result = Struct.new(
      :creatives,
      :parent_creative,
      :shared_creative,
      :shared_list,
      :overall_progress,
      :allowed_creative_ids,
      :progress_map,
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
        progress_map: result[:progress_map]
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
      params[:tags].present? ||
        params[:min_progress].present? ||
        params[:max_progress].present? ||
        params[:search].present? ||
        params[:comment] == "true" ||
        params[:has_comments].present? ||
        params[:due_before].present? ||
        params[:due_after].present? ||
        params[:has_due_date].present? ||
        params[:assignee_id].present? ||
        params[:unassigned].present?
    end

    def handle_filtered_query
      scope = determine_scope

      result = FilterPipeline.new(
        user: user,
        params: params,
        scope: scope
      ).call

      return empty_result if result.matched_ids.empty?

      # For search/comment filters, return matched items directly (flat results sorted by relevance)
      # For other filters (tags, progress), return tree start nodes
      if params[:search].present? || params[:comment] == "true"
        matched_creatives = Creative.where(id: result.matched_ids.to_a)
          .order(:sequence)
          .select { |c| readable?(c) }

        # Sort by comment updated_at for comment filter
        if params[:comment] == "true"
          matched_creatives = matched_creatives.sort_by { |c| c.comments.maximum(:updated_at) || c.updated_at }.reverse
        end

        parent = params[:id] ? Creative.find_by(id: params[:id]) : nil
        {
          creatives: matched_creatives,
          parent: parent,
          allowed_ids: result.allowed_ids,
          overall_progress: result.overall_progress,
          progress_map: result.progress_map
        }
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

    def handle_id_query
      creative = Creative.find_by(id: params[:id])
      return empty_result unless creative && readable?(creative)

      {
        creatives: creative.children_with_permission(user, :read),
        parent: creative,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    def handle_root_query
      {
        creatives: Creative.where(user: user).roots,
        parent: nil,
        allowed_ids: nil,
        overall_progress: nil,
        progress_map: nil
      }
    end

    def determine_scope
      if params[:id]
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
