module CreativesHelper
  # Shared toggle button symbol helper
  def toggle_button_symbol(expanded: false)
    expanded ? "\u25BC" : "\u25B6" # ▼ or ▶
  end

  def render_tags(labels, class_name = nil)
    return "" if labels&.empty? or labels.nil?

    index = 0
    safe_join(labels.map do |label|
      suffix = " 🗓#{label.target_date}" if label.type == "Plan"
      index += 1
      content_tag(:span, class: "tag") do
        (index == 1 ? "" : " ").html_safe +
        link_to("##{label.name}", creatives_path(tags: [ label.id ]), class: class_name ? class_name: "", title: label.name) + suffix
      end
    end)
  end

  def render_creative_progress(creative)
    content_tag(:div, style: "margin-left: 10px; color: #888; font-size: 0.9em; white-space: nowrap;") do
    content_tag(:span, number_to_percentage(creative.progress * 100, precision: 0), class: "creative-progress") +
      button_tag("(#{creative.comments.size})", name: "show-comments-btn",
                 "data-creative-id": creative.id, "style": "background: transparent;")
    end
  end

  def render_creative_tree(creatives, level = 1, select_mode: false)
    safe_join(
      creatives.map do |creative|
        drag_attrs = {
          draggable: true,
          id: "creative-#{creative.id}",
          ondragstart: "handleDragStart(event)",
          ondragover: "handleDragOver(event)",
          ondrop: "handleDrop(event)"
        }
        filtered_children = creative.children_with_permission(Current.user)
        render_next_block = ->(level) {
          (filtered_children.any? ? content_tag(:div, id: "creative-children-#{creative.id}", class: "creative-children") {
            render_creative_tree(filtered_children, level, select_mode: select_mode)
          }: "".html_safe)
        }
        render_row_content = ->(wrapper) {
          content_tag(:div, class: "creative-row-left", style: "display: flex; align-items: center;") do
            content_tag(:div, class: "creative-row-actions", style: "display: flex; align-items: center;") do
              content_tag(:div, ((level <= 3 and filtered_children.any?) ? toggle_button_symbol(expanded: true) : ""),
                          class: "before-link creative-toggle-btn",
                          style: "width: 9px; height: 9px; font-size: 9px; margin-right: 6px; display: flex; align-items: center; justify-content: center; line-height: 1; cursor: pointer;",
                          data: { creative_id: creative.id }) +
                (
                  select_mode ?
                    check_box_tag("selected_creative_ids[]", creative.id, false, class: "select-creative-checkbox", style: "margin-left: 6px; width: 16px; height: 16px; cursor: pointer; visibility: visible;") :
                    link_to("+", new_creative_path(parent_id: creative.id),
                      class: "add-creative-btn",
                      style: "margin-left: 6px; font-size: 12px; width: 12px; font-weight: bold; text-decoration: none; cursor: pointer;#{' visibility: hidden;' unless creative.has_permission?(Current.user, :write)}",
                      title: I18n.t("creatives.help.add_child_creative")
                    )
                )
            end +
            wrapper.call {
              link_to(creative.effective_description(params[:tags]&.first), creative, class: "unstyled-link")
            }
          end + render_creative_progress(creative)
        }

        # filter if params[:tags]
        skip = false
        if params[:tags].present?
          tag_ids = Array(params[:tags]).map(&:to_s)
          creative_label_ids = creative.tags.pluck(:label_id).map(&:to_s)
          skip = (creative_label_ids & tag_ids).empty?
        end
        if not skip and params[:min_progress].present?
          min_progress = params[:min_progress].to_f
          skip = creative.progress < min_progress
        end
        if not skip and params[:max_progress].present?
          max_progress = params[:max_progress].to_f
          skip = creative.progress > max_progress
        end

        if skip
          render_next_block.call level # skip this creative, so decrease level
        else
          bullet_starting_level = 3
          if level <= bullet_starting_level
            content_tag(:div, class: "creative-tree", **drag_attrs) do
              heading_tag = (filtered_children.any? or creative.parent.nil?) ? "h#{level}" : "div"
              content_tag(:div, class: "creative-row") do
                render_row_content.call(->(&block) {
                  content_tag(heading_tag, class: "indent#{level}") do
                    block.call
                  end
                })
              end
            end
          else
            # low level creative render as li
            content_tag(:div, class: "creative-tree", **drag_attrs) do
              content_tag(:div, class: "creative-row") do
                render_row_content.call(->(&block) {
                  margin = level > 0 ? "margin-left: #{(level - bullet_starting_level) * 20}px;" : ""
                  content_tag(:div, class: "creative-tree-li", style: "#{margin} display: flex; align-items: center;") do
                    if creative.effective_description.include?("<li>")
                      "".html_safe
                    else
                      content_tag(:div, "", class: "creative-tree-bullet")
                    end + block.call
                  end
                })
              end
            end
          end + render_next_block.call(level + 1)
        end
      end
    )
  end
end
