module CreativesHelper
  # Shared toggle button symbol helper
  def toggle_button_symbol(expanded: false)
    expanded ? "\u25BC" : "\u25B6" # ▼ or ▶
  end

  def render_creative_progress(creative)
    content_tag(:span, number_to_percentage(creative.progress * 100, precision: 0), class: "creative-progress", style: "margin-left: 10px; color: #888; font-size: 0.9em;")
  end

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
        render_next_block = -> {
          (creative.children_with_permission.any? ? content_tag(:div, id: "creative-children-#{creative.id}", class: "creative-children") {
            render_creative_tree(creative.children_with_permission, level + 1)
          }: "".html_safe)
        }
        render_row_content = ->(wrapper) {
          content_tag(:div, class: "creative-row-left", style: "display: flex; align-items: center;") do
            content_tag(:div, class: "creative-row-actions", style: "display: flex; align-items: center;") do
              content_tag(:div, ((level <= 3 and creative.children_with_permission.any?) ? toggle_button_symbol(expanded: true) : ""),
                          class: "before-link creative-toggle-btn",
                          style: "width: 9px; height: 9px; font-size: 9px; margin-right: 6px; display: flex; align-items: center; justify-content: center; line-height: 1; cursor: pointer;",
                          data: { creative_id: creative.id }) +
                link_to("+", new_creative_path(parent_id: creative.id),
                        class: "add-creative-btn",
                        style: "margin-left: 6px; font-size: 12px; width: 12px; font-weight: bold; text-decoration: none; cursor: pointer;#{' visibility: hidden;' unless creative.has_permission?(Current.user, :write)}",
                        title: I18n.t("creatives.help.add_child_creative")
                )
            end +
            wrapper.call {
              link_to(creative.effective_description, creative, class: "unstyled-link")
            }
          end + render_creative_progress(creative)
        }
        bullet_starting_level = 3
        if level <= bullet_starting_level
          content_tag(:div, class: "creative-tree", **drag_attrs) {
            heading_tag = (creative.children_with_permission.any? or creative.parent.nil?) ? "h#{level}" : "div"
            content_tag(:div, class: "creative-row") do
              render_row_content.call(->(&block) {
                content_tag(heading_tag, class: "indent#{level}") do
                  block.call
                end
              })
            end + render_next_block.call
          }
        else
          # low level creative render as li
          content_tag(:div, class: "creative-tree", **drag_attrs) do
            content_tag(:div, class: "creative-row") do
              render_row_content.call(->(&block) {
                margin = level > 0 ? "margin-left: #{(level - bullet_starting_level) * 20}px;" : ""
                content_tag(:div, class: "creative-tree-li", style: "#{margin} display: flex; align-items: center;") do
                  content_tag(:div, "", class: "creative-tree-bullet", style: "width: 8px; height: 8px; border-radius: 50%; background: #333; margin-right: 8px;") +
                  block.call
                end
              })
            end + render_next_block.call
          end
        end
      end
    )
  end
end
