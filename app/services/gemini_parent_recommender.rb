class GeminiParentRecommender
  def initialize(client: GeminiClient.new)
    @client = client
  end

  def recommend(creative)
    user = creative.user

    # 1. Gather all potential category candidates
    # Candidates: All creatives user can write to + creative's current parent (even if not writable?)
    # Original logic: Distinct creatives having children + parent.
    # Note: Using `joins(:children)` filters only those that have children.

    categories = Creative
                   .joins(:children)
                   .distinct
                   .select { |c| c.description.length <= 40 }
                   .select { |c| c.has_permission?(user, :write) }

    parent = creative.parent
    if parent&.has_permission?(user, :write)
      categories << parent
    end
    categories = categories.uniq

    top_level_categories = categories.reject { |c| categories.any? { |other| other.id == c.parent_id } }

    tree_text = Creatives::TreeFormatter.new.format(top_level_categories)

    ids = @client.recommend_parent_ids(tree_text,
                                       ActionController::Base.helpers.strip_tags(creative.description).to_s)

    # Reconstruct paths for result
    ids.map do |id|
       c = Creative.find_by(id: id)
       next unless c
       path = c.ancestors.reverse.map { |a| ActionController::Base.helpers.strip_tags(a.description) } + [ ActionController::Base.helpers.strip_tags(c.description) ]
       { id: id, path: path.join(" > ") }
    end.compact
  end
end
