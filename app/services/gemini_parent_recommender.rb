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
      path = (c.ancestors + [ c ]).map { |node| node.rich_text_description&.to_plain_text }.join(" > ")
      paths[c.id] = path
    end
    ids = @client.recommend_parent_ids(paths.map { |id, path| { id: id, path: path } },
                                       creative.rich_text_description&.to_plain_text.to_s)
    ids.map { |id| { id: id, path: paths[id] } }.compact
  end
end
