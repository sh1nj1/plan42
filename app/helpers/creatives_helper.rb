module CreativesHelper
  def render_creative_tree(creatives)
    content_tag(:ul) do
      creatives.map do |creative|
        concat(
          content_tag(:li) do
            concat(link_to(creative.name, creative))
            if creative.children.any?
              concat(render_creative_tree(creative.children))
            end
          end
        )
      end
    end
  end
end
