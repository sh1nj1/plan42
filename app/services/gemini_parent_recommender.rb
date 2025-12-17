class GeminiParentRecommender
  def initialize(client: default_client)
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
                   .where(origin_id: nil)
                   .select { |c| c.has_permission?(user, :write) }

    parent = creative.parent
    if parent&.has_permission?(user, :write)
      categories << parent
    end
    categories = categories.uniq

    # Rebuild tree in memory to avoid N+1 in TreeFormatter
    children_map = categories.group_by(&:parent_id)
    categories.each do |c|
      # Manually set the children association target
      c.association(:children).target = (children_map[c.id] || []).select { |child| child.has_permission?(user, :write) }
    end
    category_ids = categories.index_by(&:id)
    top_level_categories = categories.reject { |c| category_ids.key?(c.parent_id) }

    tree_text = Creatives::TreeFormatter.new.format(top_level_categories)

    prompt = build_prompt(tree_text, ActionController::Base.helpers.strip_tags(creative.description).to_s)
    Rails.logger.info("### prompt=#{prompt}")

    response = @client.chat([ { role: :user, parts: [ { text: prompt } ] } ])
    ids = parse_response(response)

    # Reconstruct paths for result
    ids.map do |id|
       c = Creative.find_by(id: id)
       next unless c
       path = c.ancestors.reverse.map { |a| ActionController::Base.helpers.strip_tags(a.description) } + [ ActionController::Base.helpers.strip_tags(c.description) ]
       { id: id, path: path.join(" > ") }
    end.compact
  end

  private

  def default_client
    AiClient.new(
      vendor: "google",
      model: "gemini-2.5-flash",
      system_prompt: nil
    )
  end

  def build_prompt(tree_text, description)
    "#{tree_text}\n\nGiven the above creative tree, which ids are the best parents for \"#{description}\"? " \
      "Reply with up to 5 ids separated by commas in descending order of relevance."
  end

  def parse_response(content)
    return [] if content.blank?

    content.to_s.split(/[\s,]+/)
           .filter_map { |value| Integer(value, exception: false) }
           .reject(&:zero?)
           .first(5)
  end
end
