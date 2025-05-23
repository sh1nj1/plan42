module CreativesHelper
  def render_creative_tree(creatives)
    content_tag(:ul) do
      creatives.map do |creative|
        concat(
          content_tag(:li) do
            concat(content_tag(:div, class: "creative-row") do
              concat(link_to(creative.description, creative, class: "unstyled-link"))
              concat(content_tag(:span, number_to_percentage(creative.progress * 100, precision: 0), class: "creative-progress", style: "margin-left: 10px; color: #888; font-size: 0.9em;"))
            end)
            if creative.children.any?
              concat(render_creative_tree(creative.children))
            end
          end
        )
      end
    end
  end
end
