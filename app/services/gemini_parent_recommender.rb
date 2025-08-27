class GeminiParentRecommender
  def initialize(client: GeminiClient.new)
    @client = client
  end

  def recommend(creative)
    user = creative.user
    categories = Creative.where(user: user).joins(:children).distinct
    paths = {}
    categories.each do |c|
      path = (c.ancestors.where(user: user) + [ c ]).map(&:description).join(" > ")
      paths[c.id] = path
    end
    ids = @client.recommend_parent_ids(paths.map { |id, path| { id: id, path: path } },
                                       creative.rich_text_description&.to_plain_text.to_s)
    ids.map { |id| { id: id, path: paths[id] } }.compact
  end
end
