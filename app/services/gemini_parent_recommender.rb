class GeminiParentRecommender
  def initialize(client: GeminiClient.new)
    @client = client
  end

  def recommend(creative)
    user = creative.user
    categories = Creative
                   .joins(:children)
                   .distinct
                   .select { |c| c.has_permission?(user, :write) }
    parent = creative.parent
    if parent&.has_permission?(user, :write)
      categories << parent
    end
    categories = categories.uniq
    paths = {}
    categories.each do |c|
      path_sequences = c.ancestors.reverse + [ c ]
      path = path_sequences.map { |node| ActionController::Base.helpers.strip_tags(node.description) }.join(" > ")
      paths[path_sequences.last.id] = path unless path_sequences.empty?
    end
    ids = @client.recommend_parent_ids(paths.map { |id, path| { id: id, path: path } },
                                       ActionController::Base.helpers.strip_tags(creative.description).to_s)
    ids.map { |id| { id: id, path: paths[id] } }.compact
  end
end
