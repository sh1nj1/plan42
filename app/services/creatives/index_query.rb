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
        Creative.all
      end

      # Apply Tag Filter
      tag_ids = Array(params[:tags]).map(&:to_s)
      matched = scope.joins(:tags).where(tags: { label_id: tag_ids }).to_a

      # Apply Progress Filter in Ruby (not SQL) to handle delegated progress on linked creatives
      if params[:min_progress].present?
        min_progress = params[:min_progress].to_f
        matched = matched.select { |c| c.progress.to_f >= min_progress }
      end

      if params[:max_progress].present?
        max_progress = params[:max_progress].to_f
        matched = matched.select { |c| c.progress.to_f <= max_progress }
      end

      # Ancestors UP TO the root of the view.
      matched_ids = matched.map(&:id)

      # Using CreativeHierarchy to find all ancestors
      ancestor_ids = CreativeHierarchy.where(descendant_id: matched_ids).pluck(:ancestor_id)

      # Filter allowed_ids by user access
      allowed_ids = (matched_ids + ancestor_ids).uniq
      creatives_to_check = Creative.where(id: allowed_ids).to_a
      accessible_creatives = creatives_to_check.select { |c| c.has_permission?(user, :read) }
      allowed_ids = accessible_creatives.map(&:id)

      # "Starting Roots" for the result.
      start_nodes = if params[:id]
        parent = Creative.find(params[:id])
        return [ [], nil, nil, 0, {} ] unless readable?(parent)

        parent.children.where(id: allowed_ids)
      else
        # Find top-most nodes from allowed_ids (reuse already-loaded creatives)
        allowed_ids_set = allowed_ids.to_set

        top_nodes = accessible_creatives.reject do |creative|
          creative.ancestor_ids.any? { |ancestor_id| allowed_ids_set.include?(ancestor_id) }
        end

        top_nodes
      end

      # Filter allowed_ids to only include readable ones?
      parent = params[:id] ? Creative.find(params[:id]) : nil

      # Calculate Progress Map
      # "Leaf-most" logic: find nodes in allowed_ids that are ancestors of OTHER nodes in allowed_ids
      superfluous_ancestors = CreativeHierarchy
                                .where(ancestor_id: allowed_ids, descendant_id: allowed_ids)
                                .where("generations > 0")
                                .pluck(:ancestor_id)
                                .uniq

      relevant_ids = allowed_ids - superfluous_ancestors
      relevant_ids = relevant_ids.uniq

      progress_map, filtered_progress = calculate_progress_map(accessible_creatives, allowed_ids, relevant_ids)

      [ start_nodes, parent, allowed_ids.map(&:to_s).to_set, filtered_progress, progress_map ]
    end

    def calculate_progress_map(accessible_creatives, allowed_ids, relevant_ids)
      return [ {}, 0.0 ] if relevant_ids.empty?

      # 1. Get properties of relevant creatives from already-loaded objects
      relevant_creatives = accessible_creatives.select { |c| relevant_ids.include?(c.id) }

      # Use actual progress for all relevant nodes
      leaf_values = relevant_creatives.to_h { |c| [ c.id, c.progress.to_f ] }

      # Calculate overall average from loaded values
      total_progress = leaf_values.values.sum
      overall_average = leaf_values.any? ? total_progress / leaf_values.size : 0.0

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
