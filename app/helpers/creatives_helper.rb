module CreativesHelper
  def render_creative_tree(creatives, level = 1)
    safe_join(
      creatives.map do |creative|
        drag_attrs = {
          draggable: true,
          id: "creative-#{creative.id}",
          ondragstart: "handleDragStart(event)",
          ondragover: "handleDragOver(event)",
          ondrop: "handleDrop(event)"
        }
        if level <= 3
          # Render as heading tag for root and second-level only
          content_tag(:div, class: "creative-tree", **drag_attrs) {
            heading_tag = (creative.children.any? or creative.parent.nil?) ? "h#{level}" : "div"
            content_tag(heading_tag, class: "creative-row indent#{level}") do
              link_to(creative.description, creative, class: "unstyled-link") +
              content_tag(:span, number_to_percentage(creative.progress * 100, precision: 0), class: "creative-progress", style: "margin-left: 10px; color: #888; font-size: 0.9em;")
            end +
            (creative.children.any? ? render_creative_tree(creative.children, level + 1) : "")
          }
        else
          # low level creative render as li
          content_tag(:ul, class: "creative-tree", **drag_attrs) {
            content_tag(:li) do
            content_tag(:div, class: "creative-row") do
              link_to(creative.description, creative, class: "unstyled-link") +
              content_tag(:span, number_to_percentage(creative.progress * 100, precision: 0), class: "creative-progress", style: "margin-left: 10px; color: #888; font-size: 0.9em;")
            end +
            (creative.children.any? ? render_creative_tree(creative.children, level + 1) : "")
            end
          }
        end
      end
    )
  end
end
