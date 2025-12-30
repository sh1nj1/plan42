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
      if params[:comment] == "true"
        creatives = Creative
                      .joins(:comments)
                      .where.not(comments: { id: nil })
                      .select { |c| readable?(c) }
                      .uniq(&:id)
        creatives = creatives.sort_by { |c| c.comments.maximum(:updated_at) || c.updated_at }.reverse
        [ creatives, nil, nil, nil, nil ]
      elsif params[:search].present?
        # Search also might need ancestor logic if we want to show path to search result?
        # Current implementation sends base_creative as parent if searching under ID.
        # For now, keeping existing search behavior.
        creatives, parent = search_creatives
        [ creatives, parent, nil, nil, nil ]
      elsif params[:tags].present?
        filter_by_tags
      elsif params[:id]
        creative = Creative.where(id: params[:id])
                            .order(:sequence)
                            .detect { |c| readable?(c) }
        [ creative&.children_with_permission(user, :read) || [], creative, nil, nil, nil ]
      else
        [ Creative.where(user: user).roots, nil, nil, nil, nil ]
      end
    end

    def filter_by_tags
      # Determine the scope
      scope = if params[:id]
        Creative.find(params[:id]).descendants
      else
        Creative.where(user: user)
      end

      # Apply Tag Filter
      tag_ids = Array(params[:tags]).map(&:to_s)
      matched = scope.joins(:tags).where(tags: { label_id: tag_ids })

      # Apply Progress Filter if present
      if params[:min_progress].present?
        matched = matched.where("progress >= ?", params[:min_progress].to_f)
      end

      if params[:max_progress].present?
        matched = matched.where("progress <= ?", params[:max_progress].to_f)
      end

      # Ancestors UP TO the root of the view.
      matched_ids = matched.pluck(:id)

      # Using CreativeHierarchy to find all ancestors
      ancestor_ids = CreativeHierarchy.where(descendant_id: matched_ids).pluck(:ancestor_id)

      # allowed_ids is the set of nodes that should be visible
      allowed_ids = (matched_ids + ancestor_ids).uniq

      # Filter allowed_ids by user access using proper permission logic
      # This handles inherited permissions, no_access overrides, etc.
      creatives_to_check = Creative.where(id: allowed_ids)
      accessible_ids = creatives_to_check.select { |c| c.has_permission?(user, :read) }.map(&:id)
      allowed_ids = accessible_ids

      # Filter for readability efficiently
      # Optimization: filter by what the user usually accesses.

      # "Starting Roots" for the result.
      start_nodes = if params[:id]
        parent = Creative.find(params[:id])
        return [ [], parent, nil, 0, {} ] unless readable?(parent)

        parent.children.where(id: allowed_ids)
      else
        # Find top-most nodes from allowed_ids
        # A node is "top" if none of its ancestors are in allowed_ids
        creatives_in_set = Creative.where(id: allowed_ids).to_a
        allowed_ids_set = allowed_ids.to_set

        top_nodes = creatives_in_set.reject do |creative|
          # If any ancestor of this creative is also in allowed_ids, it's NOT a top node
          creative.ancestor_ids.any? { |ancestor_id| allowed_ids_set.include?(ancestor_id) }
        end

        top_nodes
      end

      # Final permission check on start_nodes
      visible_start_nodes = start_nodes.select { |c| readable?(c) }

      # Filter allowed_ids to only include readable ones?
      parent = params[:id] ? Creative.find(params[:id]) : nil

      # Calculate Progress Map
      # "Leaf-most" logic: efficiently find matched nodes that are ancestors of OTHER matched nodes.
      superfluous_ancestors = CreativeHierarchy
                                .where(ancestor_id: matched_ids, descendant_id: matched_ids)
                                .where("generations > 0")
                                .pluck(:ancestor_id)
                                .uniq

      relevant_ids = matched_ids - superfluous_ancestors

      progress_map, filtered_progress = calculate_progress_map(allowed_ids, relevant_ids)

      [ visible_start_nodes, parent, allowed_ids.map(&:to_s).to_set, filtered_progress, progress_map ]
    end

    def calculate_progress_map(allowed_ids, relevant_ids)
      return [ {}, 0.0 ] if relevant_ids.empty?

      # 1. Get properties of relevant creatives (leaves)
      relevant_creatives = Creative.where(id: relevant_ids).pluck(:id, :progress)

      # Calculate overall average from loaded values to avoid extra query
      total_progress = relevant_creatives.sum { |_, p| p.to_f }
      overall_average = total_progress / relevant_creatives.size

      leaf_values = relevant_creatives.to_h
      leaf_values.transform_values!(&:to_f)

      # 2. For each allowed_id, find its relevant descendants using batch query
      relationships = CreativeHierarchy
                        .where(ancestor_id: allowed_ids, descendant_id: relevant_ids)
                        .pluck(:ancestor_id, :descendant_id)

      # 3. Aggregate values per ancestor
      aggregation = Hash.new { |h, k| h[k] = [] }

      relationships.each do |anc_id, desc_id|
        val = leaf_values[desc_id]
        aggregation[anc_id] << val if val
      end

      # 4. Compute Averages
      result = {}
      aggregation.each do |anc_id, values|
        result[anc_id.to_s] = values.sum / values.size
      end

      [ result, overall_average ]
    end

    def search_creatives
      query = "%#{params[:search]}%"
      if params[:simple].present?
        creatives = Creative
                      .where("description LIKE :q", q: query)
                      .select { |c| readable?(c) }
        [ creatives, nil ]
      elsif params[:id].present?
        base_creative = Creative.find_by(id: params[:id])&.effective_origin
        return [ [], nil ] unless base_creative

        subtree_ids = base_creative.subtree_ids
        creatives = Creative
                      .distinct
                      .left_joins(:comments)
                      .where(id: subtree_ids)
                      .where("description LIKE :q OR comments.content LIKE :q", q: query)
                      .select { |c| readable?(c) }
        [ creatives, base_creative ]
      else
        creatives = Creative
                      .distinct
                      .left_joins(:comments)
                      .where("description LIKE :q OR comments.content LIKE :q", q: query)
                      .where(origin_id: nil)
                      .select { |c| readable?(c) }
        [ creatives, nil ]
      end
    end

    def readable?(creative)
      creative.user == user || creative.has_permission?(user, :read)
    end
  end
end
