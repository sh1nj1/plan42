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
      creatives, parent, allowed_creative_ids, filtered_progress, progress_map = resolve_creatives
      shared_creative = parent || creatives&.first
      shared_list = shared_creative ? shared_creative.all_shared_users : []
      overall_progress = filtered_progress || 0

      Result.new(
        creatives: creatives,
        parent_creative: parent,
        shared_creative: shared_creative,
        shared_list: shared_list,
        overall_progress: overall_progress,
        allowed_creative_ids: allowed_creative_ids,
        progress_map: progress_map
      )
    end

    private

    attr_reader :user, :params

    def resolve_creatives
      if any_filter_active?
        handle_filtered_query
      elsif params[:id]
        creative = Creative.where(id: params[:id])
                            .order(:sequence)
                            .detect { |c| readable?(c) }
        children = children_with_linked_origins(creative)
        [ children, creative, nil, nil, nil ]
      else
        [ Creative.where(user: user).roots, nil, nil, nil, nil ]
      end
    end

    def children_with_linked_origins(creative)
      return [] unless creative

      # Actual children
      actual_children = creative.children_with_permission(user, :read)

      # Linked origins via creative_links with their sequences for proper ordering
      links = CreativeLink.where(parent_id: creative.id)
      link_sequence_map = links.each_with_object({}) { |l, h| h[l.origin_id] = l.sequence }
      linked_origins = Creative.where(id: links.pluck(:origin_id))
        .select { |c| c.has_permission?(user, :read) }

      # Sort by sequence: link.sequence for linked origins, creative.sequence for actual children
      (actual_children + linked_origins).uniq.sort_by do |c|
        link_sequence_map[c.id] || c.sequence
      end
    end

    def any_filter_active?
      params[:tags].present? ||
        params[:min_progress].present? ||
        params[:max_progress].present? ||
        params[:search].present? ||
        params[:comment] == "true"
    end

    def handle_filtered_query
      scope = accessible_creatives_scope

      result = FilterPipeline.new(
        user: user,
        params: params,
        scope: scope
      ).call

      return [ [], nil, Set.new, 0, {} ] if result.matched_ids.empty?

      # For search/comment filters, return matched items directly (flat results)
      # For other filters (tags, progress), return tree start nodes
      if params[:search].present? || params[:comment] == "true"
        matched_creatives = Creative.where(id: result.matched_ids.to_a)
          .order(:sequence)
          .select { |c| readable?(c) }
        parent = params[:id] ? Creative.find_by(id: params[:id]) : nil
        [ matched_creatives, parent, result.allowed_ids, result.overall_progress, result.progress_map ]
      else
        start_nodes = determine_start_nodes(result.allowed_ids)
        parent = params[:id] ? Creative.find_by(id: params[:id]) : nil
        [ start_nodes, parent, result.allowed_ids, result.overall_progress, result.progress_map ]
      end
    end

    def accessible_creatives_scope
      if params[:id]
        base_creative = Creative.find(params[:id])
        # Include actual descendants
        actual_descendant_ids = base_creative.self_and_descendant_ids

        # Include virtually linked descendants via VirtualCreativeHierarchy
        virtual_descendant_ids = VirtualCreativeHierarchy
          .where(ancestor_id: actual_descendant_ids)
          .pluck(:descendant_id)

        Creative.where(id: (actual_descendant_ids + virtual_descendant_ids).uniq)
      else
        Creative.where(user: user)
      end
    end

    def determine_start_nodes(allowed_ids)
      allowed_ids_array = allowed_ids.map(&:to_i)
      allowed_ids_set = allowed_ids_array.to_set

      if params[:id]
        parent = Creative.find(params[:id])
        return [] unless readable?(parent)

        # Include actual children
        actual_children = parent.children.where(id: allowed_ids_array).order(:sequence).to_a
        actual_children_ids = actual_children.map(&:id).to_set

        # Include virtually linked children (origins from CreativeLinks)
        # Need to track link.sequence for proper ordering
        links = CreativeLink.where(parent_id: parent.id).where(origin_id: allowed_ids_array)
        link_sequence_map = links.each_with_object({}) { |l, h| h[l.origin_id] = l.sequence }
        virtual_children = Creative.where(id: links.pluck(:origin_id)).to_a

        # Merge and sort: actual children by creative.sequence, linked origins by link.sequence
        all_children = (actual_children + virtual_children).uniq
        all_children.sort_by do |c|
          link_sequence_map[c.id] || c.sequence
        end
      else
        # Find top-most nodes from allowed_ids
        creatives = Creative.where(id: allowed_ids_array).to_a

        creatives.reject do |creative|
          # Check real ancestors
          has_real_ancestor = creative.ancestor_ids.any? { |ancestor_id| allowed_ids_set.include?(ancestor_id) }

          # Check virtual ancestors
          has_virtual_ancestor = VirtualCreativeHierarchy
            .where(descendant_id: creative.id, ancestor_id: allowed_ids_array)
            .where.not(ancestor_id: creative.id)
            .exists?

          has_real_ancestor || has_virtual_ancestor
        end.sort_by(&:sequence)
      end
    end

    def readable?(creative)
      creative.user == user || creative.has_permission?(user, :read)
    end
  end
end
